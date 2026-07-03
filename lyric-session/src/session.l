//! Session — distributed session management for Lyric web applications.
//!
//! Stability: @experimental — the surface compiles and the in-memory
//! store has tests, but the Redis-backed store has not been exercised
//! against a real Redis cluster in CI.
//! WARNING: experimental — no stability guarantee.  Public functions
//! may change shape, add parameters, or be renamed before the surface
//! freezes for `1.0`.
//!
//! Provides a `SessionStore` interface with Redis-backed and in-process
//! implementations.  Both share the same API; swap the store at startup
//! via factory functions without changing application code.
//!
//! Typical usage:
//!
//!   import Session
//!
//!   // In-process (single-instance):
//!   var store = Session.inMemory()
//!
//!   // Redis-backed (multi-instance):
//!   match Session.connectRedis() {
//!     case Ok(store) -> ...
//!     case Err(e)    -> ...
//!   }
//!
//!   // Use the store:
//!   match Session.create(store) {
//!     case Ok(sessionId) ->
//!       Session.set(store, sessionId, "userId", "42")
//!     case Err(e) -> ...
//!   }
//!
//! Runtime config env vars (LYRIC_CONFIG_SESSION_*):
//!   LYRIC_CONFIG_SESSION_SESSION_TTLSECONDS    — session TTL in seconds (default: 3600)
//!   LYRIC_CONFIG_SESSION_SESSION_COOKIENAME    — session cookie name (default: LYRIC_SESSION)
//!   LYRIC_CONFIG_SESSION_SESSION_SECURE        — Secure cookie flag (default: true)
//!   LYRIC_CONFIG_SESSION_SESSION_HTTPONLY      — HttpOnly cookie flag (default: true)
//!   LYRIC_CONFIG_SESSION_SESSION_SAMESITE      — SameSite policy (default: Lax)
//!   LYRIC_CONFIG_SESSION_REDISSESSION_URL      — Redis connection URL (redis feature)
//!   LYRIC_CONFIG_SESSION_REDISSESSION_KEYPREFIX — key namespace prefix (default: session:)
@runtime_checked
package Session

import Std.Core
import Std.Collections
import Std.String
import Std.Time
import Std.Json
import Std.Uuid
import Std.Environment as Env
import Std.Parse
import Session.Kernel.Net as SessionKernel

// ─── Session identity ─────────────────────────────────────────────────────────
/// Session identifier: a plain String assigned by the store at creation time.
@stable(since = "0.1")
pub alias SessionId = String

// ─── Error type ───────────────────────────────────────────────────────────────
/// Error returned by SessionStore operations.
@stable(since = "0.1")
pub record SessionError {
  message: String
  code: String
}

// ─── Session data ─────────────────────────────────────────────────────────────
/// A single key-value entry in a session.
@stable(since = "0.1")
pub record SessionEntry {
  key: String
  value: String
}

/// The full contents of a session, including timing metadata.
@stable(since = "0.1")
pub record SessionData {
  id: String
  entries: Map[String, String]
  createdAt: Long   // epoch millis
  lastAccessedAt: Long   // epoch millis
  expiresAt: Long   // epoch millis; 0 = no expiry
}

// ─── Store interface ──────────────────────────────────────────────────────────
/// Backing store for session state.  Implement this interface to plug in
/// alternative stores.  Use `Session.inMemory()` or `Session.connectRedis()`
/// for the bundled implementations.
@stable(since = "0.1")
pub interface SessionStore {
  /// Create a new empty session and return its ID.
  func create(): Result[String, SessionError]

  /// Load a session by ID.  Returns None if the session does not exist or
  /// has expired.
  func load(sessionId: in String): Result[Option[SessionData], SessionError]

  /// Persist the given session data, replacing any existing entry for the
  /// same ID.
  func save(data: in SessionData): Result[Unit, SessionError]

  /// Permanently remove a session.  No-op if not found.
  func destroy(sessionId: in String): Result[Unit, SessionError]

  /// Refresh the session expiry without changing its contents.
  func touch(sessionId: in String): Result[Unit, SessionError]

  /// Return the value for a key in the session, or None if absent.
  func get(sessionId: in String, key: in String): Result[Option[String], SessionError]

  /// Set a key-value pair in the session, creating the session if it does
  /// not already exist.
  func set(sessionId: in String, key: in String, value: in String): Result[Unit, SessionError]

  /// Remove a key from the session.  No-op if the key is absent.
  func delete(sessionId: in String, key: in String): Result[Unit, SessionError]

  /// Remove all keys from the session without destroying the session itself.
  func clear(sessionId: in String): Result[Unit, SessionError]
}

// ─── Native (Redis) store ─────────────────────────────────────────────────────
/// Redis-backed session store.  Obtain via `Session.connectRedis()`.
///
/// **NOTE:** `set`, `delete`, `clear`, and `touch` perform load-modify-save
/// round-trips without atomic Redis transactions.  Concurrent mutations to
/// the same session may result in lost updates.  This is an `@experimental`
/// limitation; atomic Redis Lua-script operations are tracked as a follow-up.
@experimental
@cfg(feature = "redis")
pub record NativeSessionStore {
  storeHandle: SessionKernel.RedisStoreHandle
  // Session TTL in seconds, read from `LYRIC_CONFIG_SESSION_SESSION_TTLSECONDS`
  // by `connectRedis()` (default 3600).  Previously `create`/`touch` hardcoded
  // 3600 directly and ignored this env var entirely (#3553).
  ttlSeconds: Int
}

@experimental
@cfg(feature = "redis")
impl SessionStore for NativeSessionStore {
  func create(): Result[String, SessionError] {
    match SessionKernel.create(self.storeHandle, self.ttlSeconds) {
      case Ok(id) -> Ok(id)
      case Err(err) -> Err(SessionError(message = err, code = "CREATE_FAILED"))
    }
  }

  func load(sessionId: in String): Result[Option[SessionData], SessionError] {
    match SessionKernel.load(self.storeHandle, sessionId) {
      case Ok(json) -> if json == "" { Ok(None) } else { Ok(Some(value = parseSessionJson(sessionId, json))) }
      case Err(err) -> Err(SessionError(message = err, code = "LOAD_FAILED"))
    }
  }

  func save(data: in SessionData): Result[Unit, SessionError] {
    val json = serializeSessionJson(data)
    match SessionKernel.save(self.storeHandle, data.id, json) {
      case Ok(u) -> Ok(u)
      case Err(err) -> Err(SessionError(message = err, code = "SAVE_FAILED"))
    }
  }

  func destroy(sessionId: in String): Result[Unit, SessionError] {
    match SessionKernel.destroy(self.storeHandle, sessionId) {
      case Ok(u) -> Ok(u)
      case Err(err) -> Err(SessionError(message = err, code = "DESTROY_FAILED"))
    }
  }

  func touch(sessionId: in String): Result[Unit, SessionError] {
    match SessionKernel.touch(self.storeHandle, sessionId, self.ttlSeconds) {
      case Ok(u) -> Ok(u)
      case Err(err) -> Err(SessionError(message = err, code = "TOUCH_FAILED"))
    }
  }

  func get(sessionId: in String, key: in String): Result[Option[String], SessionError] {
    match load(sessionId) {
      case Ok(opt) -> match opt { case None -> Ok(None); case Some(data) -> Ok(mapGet(data.entries, key)) }
      case Err(e) -> Err(e)
    }
  }

  func set(sessionId: in String, key: in String, value: in String): Result[Unit, SessionError] {
    // SECURITY: do NOT auto-create a session here.  Allowing `set()`
    // to materialise a session for a caller-supplied id is a classic
    // session-fixation vector — an attacker who plants a known cookie
    // value can have it elevated when the legitimate user signs in.
    // The caller must obtain a fresh id from `create()` first.  See
    // RFC 6265 §8.4 and lyric-lang #316.
    match load(sessionId) {
      case Ok(opt) -> match opt { case None -> Err(SessionError(message = "session not found; call create() to obtain a fresh id before set()", code = "SESSION_NOT_FOUND")); case Some(existing) -> { existing.entries[key] = value; val updated = SessionData(id = existing.id, entries = existing.entries, createdAt = existing.createdAt, lastAccessedAt = nowMs(), expiresAt = existing.expiresAt); save(updated) } }
      case Err(e) -> Err(e)
    }
  }

  func delete(sessionId: in String, key: in String): Result[Unit, SessionError] {
    match load(sessionId) {
      case Ok(opt) -> match opt { case None -> Ok(()); case Some(data) -> { data.entries.remove(key); val updated = SessionData(id = data.id, entries = data.entries, createdAt = data.createdAt, lastAccessedAt = nowMs(), expiresAt = data.expiresAt); save(updated) } }
      case Err(e) -> Err(e)
    }
  }

  func clear(sessionId: in String): Result[Unit, SessionError] {
    match load(sessionId) {
      case Ok(opt) -> match opt { case None -> Ok(()); case Some(data) -> { val updated = SessionData(id = data.id, entries = newMap(), createdAt = data.createdAt, lastAccessedAt = nowMs(), expiresAt = data.expiresAt); save(updated) } }
      case Err(e) -> Err(e)
    }
  }
}

// ─── In-process store ─────────────────────────────────────────────────────────
/// In-process session store backed by a mutable Map.
///
/// Suitable for single-instance deployments or development.  Session state is
/// lost on process restart.  Not thread-safe; wrap in a protected type for
/// concurrent access once the protected-type weaver ships.
@stable(since = "0.1")
pub record InProcessSessionStore {
  var sessions: Map[String, SessionData]
  ttlSeconds: Long
}

impl SessionStore for InProcessSessionStore {
  func create(): Result[String, SessionError] {
    val id = uuidToString(newUuid())
    val ts = nowMs()
    val data = SessionData(
      id = id,
      entries = newMap(),
      createdAt = ts,
      lastAccessedAt = ts,
      expiresAt = defaultExpiresAt(self.ttlSeconds)
    )
    self.sessions[id] = data
    return Ok(id)
  }

  func load(sessionId: in String): Result[Option[SessionData], SessionError] {
    // Use containsKey + indexer instead of mapGet to avoid isinst
    // TypeBuilderInstantiation issues with Option[SessionData] pattern
    // matching when SessionData is defined in the same compilation unit.
    if not self.sessions.containsKey(sessionId) {
      Ok(None)
    } else {
      val data = self.sessions[sessionId]
      val ts = nowMs()
      if data.expiresAt != 0i64 and data.expiresAt < ts {
        self.sessions.remove(sessionId)
        Ok(None)
      } else {
        Ok(Some(value = data))
      }
    }
  }

  func save(data: in SessionData): Result[Unit, SessionError] {
    self.sessions[data.id] = data
    return Ok(())
  }

  func destroy(sessionId: in String): Result[Unit, SessionError] {
    self.sessions.remove(sessionId)
    return Ok(())
  }

  func touch(sessionId: in String): Result[Unit, SessionError] {
    if not self.sessions.containsKey(sessionId) {
      Ok(())
    } else {
      val data = self.sessions[sessionId]
      val ts = nowMs()
      if data.expiresAt != 0i64 and data.expiresAt < ts {
        self.sessions.remove(sessionId)
        Ok(())
      } else {
        val updated = SessionData(
          id = data.id,
          entries = data.entries,
          createdAt = data.createdAt,
          lastAccessedAt = ts,
          expiresAt = defaultExpiresAt(self.ttlSeconds)
        )
        self.save(updated)
      }
    }
  }

  func get(sessionId: in String, key: in String): Result[Option[String], SessionError] {
    if not self.sessions.containsKey(sessionId) {
      Ok(None)
    } else {
      val data = self.sessions[sessionId]
      val ts = nowMs()
      if data.expiresAt != 0i64 and data.expiresAt < ts {
        self.sessions.remove(sessionId)
        Ok(None)
      } else {
        Ok(mapGet(data.entries, key))
      }
    }
  }

  func set(sessionId: in String, key: in String, value: in String): Result[Unit, SessionError] {
    // SECURITY: do NOT auto-create a session here — see #316 and the
    // matching NativeSessionStore.set() comment.  Callers must obtain
    // a fresh id from create() before invoking set().
    if not self.sessions.containsKey(sessionId) {
      Err(
        SessionError(
          message = "session not found; call create() to obtain a fresh id before set()",
          code = "SESSION_NOT_FOUND"
        )
      )
    } else {
      val existing = self.sessions[sessionId]
      val ts = nowMs()
      if existing.expiresAt != 0i64 and existing.expiresAt < ts {
        self.sessions.remove(sessionId)
        Err(
          SessionError(
            message = "session not found; call create() to obtain a fresh id before set()",
            code = "SESSION_NOT_FOUND"
          )
        )
      } else {
        existing.entries[key] = value
        val updated = SessionData(
          id = existing.id,
          entries = existing.entries,
          createdAt = existing.createdAt,
          lastAccessedAt = ts,
          expiresAt = existing.expiresAt
        )
        self.save(updated)
      }
    }
  }

  func delete(sessionId: in String, key: in String): Result[Unit, SessionError] {
    if not self.sessions.containsKey(sessionId) {
      Ok(())
    } else {
      val data = self.sessions[sessionId]
      val ts = nowMs()
      if data.expiresAt != 0i64 and data.expiresAt < ts {
        self.sessions.remove(sessionId)
        Ok(())
      } else {
        data.entries.remove(key)
        val updated = SessionData(
          id = data.id,
          entries = data.entries,
          createdAt = data.createdAt,
          lastAccessedAt = nowMs(),
          expiresAt = data.expiresAt
        )
        self.save(updated)
      }
    }
  }

  func clear(sessionId: in String): Result[Unit, SessionError] {
    if not self.sessions.containsKey(sessionId) {
      Ok(())
    } else {
      val data = self.sessions[sessionId]
      val ts = nowMs()
      if data.expiresAt != 0i64 and data.expiresAt < ts {
        self.sessions.remove(sessionId)
        Ok(())
      } else {
        val updated = SessionData(
          id = data.id,
          entries = newMap(),
          createdAt = data.createdAt,
          lastAccessedAt = nowMs(),
          expiresAt = data.expiresAt
        )
        self.save(updated)
      }
    }
  }
}

// ─── Runtime config ───────────────────────────────────────────────────────────
// Session lifetime and cookie settings are read from environment variables at
// runtime: LYRIC_CONFIG_SESSION_SESSION_TTLSECONDS, LYRIC_CONFIG_SESSION_SESSION_COOKIENAME,
// LYRIC_CONFIG_SESSION_SESSION_SECURE, LYRIC_CONFIG_SESSION_SESSION_HTTPONLY,
// LYRIC_CONFIG_SESSION_SESSION_SAMESITE, LYRIC_CONFIG_SESSION_REDISSESSION_URL — see
// the module header above and docs/25-config-blocks.md's
// LYRIC_CONFIG_<PKG>_<BLOCK>_<FIELD> naming rule (pkg "Session" + block
// "Session" doubles the segment; RedisSession is a distinct block, so it
// doesn't).

// Parse `LYRIC_CONFIG_SESSION_SESSION_TTLSECONDS`, falling back to
// `defaultValue` for a malformed or negative value.  Mirrors
// `Web.parseCorsMaxAge`'s fail-soft parsing idiom.  Not `pub` — only used
// internally by `connectRedis()` in this file.
func parseSessionTtlSeconds(ttlStr: in String, defaultValue: in Int): Int {
  match tryParseInt(ttlStr) {
    case Ok(t) -> if t >= 0 { t } else { defaultValue }
    case Err(_) -> defaultValue
  }
}

// ─── Factory ──────────────────────────────────────────────────────────────────
/// Connect to Redis and return a distributed session store.
/// Reads connection settings from the RedisSession config block:
/// `LYRIC_CONFIG_SESSION_REDISSESSION_URL` (required — `Err(MISSING_REDIS_URL)`
/// when absent/empty, rather than tripping the kernel's `requires: url.length
/// > 0` precondition), `LYRIC_CONFIG_SESSION_REDISSESSION_KEYPREFIX` (default
/// `session:`), and `LYRIC_CONFIG_SESSION_SESSION_TTLSECONDS` (default 3600 —
/// previously hardcoded and silently ignored by `create`/`touch`, #3553).
///
/// Any error message returned by the kernel is routed through
/// `maskUrlCredentials` so a connection string the kernel chose to
/// echo back (StackExchange.Redis sometimes embeds the connect string
/// in `RedisConnectionException`) cannot leak the embedded password
/// into the caller's error surface (#357 / #477 / #1071).
@stable(since = "0.1")
@cfg(feature = "redis")
pub func connectRedis(): Result[SessionStore, SessionError] {
  val url = Env.getVarOrDefault("LYRIC_CONFIG_SESSION_REDISSESSION_URL", "")
  if url.length == 0 {
    return Err(
      SessionError(
        message = "LYRIC_CONFIG_SESSION_REDISSESSION_URL is not set; connectRedis() requires a Redis connection URL",
        code = "MISSING_REDIS_URL"
      )
    )
  }
  val keyPrefix = Env.getVarOrDefault("LYRIC_CONFIG_SESSION_REDISSESSION_KEYPREFIX", "session:")
  val ttlStr = Env.getVarOrDefault("LYRIC_CONFIG_SESSION_SESSION_TTLSECONDS", "3600")
  val ttlSeconds = parseSessionTtlSeconds(ttlStr, 3600)
  match SessionKernel.connect(url, keyPrefix) {
    case Ok(handle) -> Ok(NativeSessionStore(storeHandle = handle, ttlSeconds = ttlSeconds))
    case Err(err) -> Err(SessionError(message = maskUrlCredentials(err), code = "CONNECT_FAILED"))
  }
}

/// Create an in-process session store using the configured TTL.
@stable(since = "0.1")
pub func inMemory(): InProcessSessionStore {
  return InProcessSessionStore(sessions = newMap(), ttlSeconds = 3600i64)
}

// ─── Convenience public API ───────────────────────────────────────────────────
/// Create a new empty session and return its ID.
@stable(since = "0.1")
pub func create(store: in SessionStore): Result[String, SessionError] {
  return store.create()
}

/// Load a session by ID.  Returns None if the session does not exist or has expired.
@stable(since = "0.1")
pub func load(store: in SessionStore, sessionId: in String): Result[Option[SessionData], SessionError] {
  return store.load(sessionId)
}

/// Persist a session.
@stable(since = "0.1")
pub func save(store: in SessionStore, data: in SessionData): Result[Unit, SessionError] {
  return store.save(data)
}

/// Permanently remove a session.
@stable(since = "0.1")
pub func destroy(store: in SessionStore, sessionId: in String): Result[Unit, SessionError] {
  return store.destroy(sessionId)
}

/// Refresh a session's expiry without changing its contents.
@stable(since = "0.1")
pub func touch(store: in SessionStore, sessionId: in String): Result[Unit, SessionError] {
  return store.touch(sessionId)
}

/// Return the value for a key in the session.
@stable(since = "0.1")
pub func get(store: in SessionStore, sessionId: in String, key: in String): Result[Option[String], SessionError] {
  return store.get(sessionId, key)
}

/// Set a key-value pair in the session.
///
/// Returns `Err(SessionError { code = "SESSION_NOT_FOUND", ... })`
/// when `sessionId` does not name an existing session — `set()` does
/// not auto-create.  This is intentional: see #316 (session
/// fixation).  Callers must obtain a fresh id from `create()` first.
@stable(since = "0.1")
pub func set(store: in SessionStore, sessionId: in String, key: in String, value: in String): Result[Unit, SessionError] {
  return store.set(sessionId, key, value)
}

/// Remove a key from the session.
///
/// Returns `Ok(())` when `sessionId` does not name an existing
/// session: removal is idempotent in the absence of state.  This is
/// the standard "delete-of-nothing-is-a-no-op" convention.  Contrast
/// with `set()`, which surfaces `SESSION_NOT_FOUND` so a fixation
/// attempt cannot create the missing session as a side-effect.
@stable(since = "0.1")
pub func delete(store: in SessionStore, sessionId: in String, key: in String): Result[Unit, SessionError] {
  return store.delete(sessionId, key)
}

/// Remove all keys from a session without destroying it.
///
/// Like `delete()`, returns `Ok(())` when `sessionId` does not name
/// an existing session.
@stable(since = "0.1")
pub func clear(store: in SessionStore, sessionId: in String): Result[Unit, SessionError] {
  return store.clear(sessionId)
}

// ─── URL credential masking ───────────────────────────────────────────────────
/// Replace the password portion of a `scheme://user:password@host[:port][/...]`
/// URL with `***`, leaving every other component intact.
///
/// Defensive helper used at the kernel boundary so that connection
/// failures, log lines, and exception messages built from a Redis URL
/// never leak the embedded password in plaintext (#357 / #477 / #1071).
/// The function is `@pure`: pure-text rewriting only, no allocation of
/// any token store and no validation of the host/scheme — invalid or
/// non-URL inputs (no `://`, no userinfo, no `:` in userinfo, `@`
/// after the path separator) round-trip unchanged so callers can route
/// any string through it without first parsing.
///
/// Examples:
///   `redis://user:s3cr3t@host:6379/0`  → `redis://user:***@host:6379/0`
///   `rediss://:s3cr3t@host:6379`       → `rediss://:***@host:6379`
///   `redis://host:6379/0`              → `redis://host:6379/0`
///   `not a url`                        → `not a url`
@pure
@stable(since = "0.1")
pub func maskUrlCredentials(url: in String): String {
  // Find the scheme separator.
  match indexOf(url, "://") {
    case None -> url
    case Some(schemeEnd) -> {
      val authStart = schemeEnd + 3
      if authStart >= url.length {
        return url
      }
      val tail = substring(url, authStart)
      // Authority component runs until the path/query/fragment marker.
      // Pin the boundary so an `@` in a later path segment can't be
      // mistaken for an authority delimiter.
      var authEnd = tail.length
      val markers: List[String] = newList()
      markers.add("/")
      markers.add("?")
      markers.add("#")
      var mi = 0
      while mi < markers.count {
        match indexOf(tail, markers[mi]) {
          case Some(n) -> if n < authEnd { authEnd = n }
          case None -> ()
        }
        mi = mi + 1
      }
      val authority = substring(tail, 0, authEnd)
      val rest = substring(tail, authEnd)
      // userinfo terminates at the first `@` inside the authority.
      match indexOf(authority, "@") {
        case None -> url   // no credentials present
        case Some(atIx) -> {
          val userinfo = substring(authority, 0, atIx)
          val hostport = substring(authority, atIx)   // includes the `@`
          match indexOf(userinfo, ":") {
            case None -> url   // username-only, no password to mask
            case Some(colon) -> {
              val user = substring(userinfo, 0, colon)
              return substring(url, 0, schemeEnd + 3) + user + ":***" + hostport + rest
            }
          }
        }
      }
    }
  }
}

// ─── Private helpers ──────────────────────────────────────────────────────────
// Current time in epoch milliseconds.
func nowMs(): Long {
  return nowEpochMillis()
}

// Compute an expiry timestamp: 0i64 if ttlSeconds == 0i64 (no expiry),
// otherwise nowMs() + ttlSeconds * 1000i64.
func defaultExpiresAt(ttlSeconds: in Long): Long {
  if ttlSeconds == 0i64 {
    return 0i64
  }
  return nowMs() + ttlSeconds * 1000i64
}

// Escape a string for JSON serialization (handles \, ", and control chars).
// Only used by the Redis backend.
@cfg(feature = "redis")
func jsonEscapeStr(s: in String): String {
  return encodeString(s)
}

// Serialize SessionData to the protocol JSON format consumed by
// Session.Kernel.Net.save / load when using the Redis store.
@cfg(feature = "redis")
func serializeSessionJson(data: in SessionData): String {
  var entriesJson = "{"
  var first = true
  for k in data.entries {
    val v = data.entries[k]
    if not first {
      entriesJson = entriesJson + ","
    }
    entriesJson = entriesJson + "\"" + jsonEscapeStr(k) + "\":\"" + jsonEscapeStr(v) + "\""
    first = false
  }
  entriesJson = entriesJson + "}"
  return "{\"id\":\"" + jsonEscapeStr(data.id) + "\"," + "\"createdAt\":" + data.createdAt.toString() + "," +
    "\"lastAccessedAt\":" +
    data.lastAccessedAt.toString() +
    "," +
    "\"expiresAt\":" +
    data.expiresAt.toString() +
    "," +
    "\"entries\":" +
    entriesJson +
    "}"
}

// Deserialize the SessionData protocol format returned by Session.Kernel.Net.load.
// Wire format: {"id":"...","createdAt":N,"lastAccessedAt":N,"expiresAt":N,"entries":{...}}
@cfg(feature = "redis")
func parseSessionJson(sessionId: in String, json: in String): SessionData {
  val doc = parseJson(json)
  val root = rootElement(doc)
  var createdAt: Long = 0i64
  var lastAccessedAt: Long = 0i64
  var expiresAt: Long = 0i64
  var entries: Map[String, String] = newMap()
  match tryGetProperty(root, "createdAt") {
    case Some(v) -> match tryGetLong(v) { case Some(n) -> { createdAt = n }; case None -> () }
    case None -> ()
  }
  match tryGetProperty(root, "lastAccessedAt") {
    case Some(v) -> match tryGetLong(v) { case Some(n) -> { lastAccessedAt = n }; case None -> () }
    case None -> ()
  }
  match tryGetProperty(root, "expiresAt") {
    case Some(v) -> match tryGetLong(v) { case Some(n) -> { expiresAt = n }; case None -> () }
    case None -> ()
  }
  match tryGetProperty(root, "entries") {
    case Some(obj) -> {
      var en = enumerateObject(obj)
      while objectMoveNext(en) {
        val prop = objectCurrent(en)
        val k = propertyName(prop)
        val v = getString(propertyValue(prop))
        entries[k] = v
      }
    }
    case None -> ()
  }
  return SessionData(
    id = sessionId,
    entries = entries,
    createdAt = createdAt,
    lastAccessedAt = lastAccessedAt,
    expiresAt = expiresAt
  )
}
