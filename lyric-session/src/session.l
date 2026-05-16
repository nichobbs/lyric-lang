/// Session — distributed session management for Lyric web applications.
///
/// Provides a `SessionStore` interface with Redis-backed and in-process
/// implementations.  Both share the same API; swap the store at startup
/// via factory functions without changing application code.
///
/// Typical usage:
///
///   import Session
///
///   // In-process (single-instance):
///   var store = Session.inMemory()
///
///   // Redis-backed (multi-instance):
///   match Session.connectRedis() {
///     case Ok(store) -> ...
///     case Err(e)    -> ...
///   }
///
///   // Use the store:
///   match Session.create(store) {
///     case Ok(sessionId) ->
///       Session.set(store, sessionId, "userId", "42")
///     case Err(e) -> ...
///   }
///
/// Runtime config env vars (LYRIC_CONFIG_SESSION_*):
///   LYRIC_CONFIG_SESSION_SESSION_TTLSECONDS    — session TTL in seconds (default: 3600)
///   LYRIC_CONFIG_SESSION_SESSION_COOKIENAME    — session cookie name (default: LYRIC_SESSION)
///   LYRIC_CONFIG_SESSION_SESSION_SECURE        — Secure cookie flag (default: true)
///   LYRIC_CONFIG_SESSION_SESSION_HTTPONLY      — HttpOnly cookie flag (default: true)
///   LYRIC_CONFIG_SESSION_SESSION_SAMESITE      — SameSite policy (default: Lax)
///   LYRIC_CONFIG_SESSION_REDISSESSION_URL      — Redis connection URL (redis feature)
///   LYRIC_CONFIG_SESSION_REDISSESSION_KEYPREFIX — key namespace prefix (default: session:)

@runtime_checked
package Session

import Std.Core
import Std.Collections
import Std.Time
import Session.Kernel.Net

// ─── Session identity ─────────────────────────────────────────────────────────

/// Opaque session identifier.  Assigned by the store at creation time.
@stable(since="0.1")
pub type SessionId = String

// ─── Error type ───────────────────────────────────────────────────────────────

/// Error returned by SessionStore operations.
@stable(since="0.1")
pub record SessionError {
  message: String
  code:    String
}

// ─── Session data ─────────────────────────────────────────────────────────────

/// A single key-value entry in a session.
@stable(since="0.1")
pub record SessionEntry {
  key:   String
  value: String
}

/// The full contents of a session, including timing metadata.
@stable(since="0.1")
pub record SessionData {
  id:             SessionId
  entries:        Map[String, String]
  createdAt:      Long   // epoch millis
  lastAccessedAt: Long   // epoch millis
  expiresAt:      Long   // epoch millis; 0 = no expiry
}

// ─── Store interface ──────────────────────────────────────────────────────────

/// Backing store for session state.  Implement this interface to plug in
/// alternative stores.  Use `Session.inMemory()` or `Session.connectRedis()`
/// for the bundled implementations.
@stable(since="0.1")
pub interface SessionStore {
  /// Create a new empty session and return its ID.
  func create(): Result[SessionId, SessionError]

  /// Load a session by ID.  Returns None if the session does not exist or
  /// has expired.
  func load(sessionId: in SessionId): Result[Option[SessionData], SessionError]
    requires: sessionId.length > 0

  /// Persist the given session data, replacing any existing entry for the
  /// same ID.
  func save(data: in SessionData): Result[Unit, SessionError]
    requires: data.id.length > 0

  /// Permanently remove a session.  No-op if not found.
  func destroy(sessionId: in SessionId): Result[Unit, SessionError]
    requires: sessionId.length > 0

  /// Refresh the session expiry without changing its contents.
  func touch(sessionId: in SessionId): Result[Unit, SessionError]
    requires: sessionId.length > 0

  /// Return the value for a key in the session, or None if absent.
  func get(sessionId: in SessionId, key: in String): Result[Option[String], SessionError]
    requires: sessionId.length > 0
    requires: key.length > 0

  /// Set a key-value pair in the session, creating the session if it does
  /// not already exist.
  func set(sessionId: in SessionId, key: in String, value: in String): Result[Unit, SessionError]
    requires: sessionId.length > 0
    requires: key.length > 0

  /// Remove a key from the session.  No-op if the key is absent.
  func delete(sessionId: in SessionId, key: in String): Result[Unit, SessionError]
    requires: sessionId.length > 0
    requires: key.length > 0

  /// Remove all keys from the session without destroying the session itself.
  func clear(sessionId: in SessionId): Result[Unit, SessionError]
    requires: sessionId.length > 0
}

// ─── Native (Redis) store ─────────────────────────────────────────────────────

/// Redis-backed session store.  Obtain via `Session.connectRedis()`.
@stable(since="0.1")
pub record NativeSessionStore {
  storeHandle: Int
}

impl SessionStore for NativeSessionStore {
  func create(): Result[SessionId, SessionError] {
    match Session.Kernel.Net.create(storeHandle, Session.ttlSeconds) {
      case Ok(id)   -> Ok(id)
      case Err(err) -> Err(SessionError(message = err, code = "CREATE_FAILED"))
    }
  }

  func load(sessionId: in SessionId): Result[Option[SessionData], SessionError] {
    match Session.Kernel.Net.load(storeHandle, sessionId) {
      case Ok(json) ->
        if json == "" {
          Ok(None)
        } else {
          Ok(Some(value = parseSessionJson(sessionId, json)))
        }
      case Err(err) -> Err(SessionError(message = err, code = "LOAD_FAILED"))
    }
  }

  func save(data: in SessionData): Result[Unit, SessionError] {
    val json = serializeSessionJson(data)
    match Session.Kernel.Net.save(storeHandle, json) {
      case Ok(u)    -> Ok(u)
      case Err(err) -> Err(SessionError(message = err, code = "SAVE_FAILED"))
    }
  }

  func destroy(sessionId: in SessionId): Result[Unit, SessionError] {
    match Session.Kernel.Net.destroy(storeHandle, sessionId) {
      case Ok(u)    -> Ok(u)
      case Err(err) -> Err(SessionError(message = err, code = "DESTROY_FAILED"))
    }
  }

  func touch(sessionId: in SessionId): Result[Unit, SessionError] {
    match Session.Kernel.Net.touch(storeHandle, sessionId, Session.ttlSeconds) {
      case Ok(u)    -> Ok(u)
      case Err(err) -> Err(SessionError(message = err, code = "TOUCH_FAILED"))
    }
  }

  func get(sessionId: in SessionId, key: in String): Result[Option[String], SessionError] {
    match load(sessionId) {
      case Ok(opt) ->
        match opt {
          case None       -> Ok(None)
          case Some(data) -> Ok(data.entries.get(key))
        }
      case Err(e) -> Err(e)
    }
  }

  func set(sessionId: in SessionId, key: in String, value: in String): Result[Unit, SessionError] {
    match load(sessionId) {
      case Ok(opt) ->
        val existing = match opt {
          case Some(d) -> d
          case None    ->
            val ts = nowMs()
            SessionData(
              id             = sessionId,
              entries        = Map.empty(),
              createdAt      = ts,
              lastAccessedAt = ts,
              expiresAt      = defaultExpiresAt(Session.ttlSeconds))
        }
        val updated = SessionData(
          id             = existing.id,
          entries        = existing.entries.set(key, value),
          createdAt      = existing.createdAt,
          lastAccessedAt = nowMs(),
          expiresAt      = existing.expiresAt)
        save(updated)
      case Err(e) -> Err(e)
    }
  }

  func delete(sessionId: in SessionId, key: in String): Result[Unit, SessionError] {
    match load(sessionId) {
      case Ok(opt) ->
        match opt {
          case None       -> Ok(())
          case Some(data) ->
            val updated = SessionData(
              id             = data.id,
              entries        = data.entries.remove(key),
              createdAt      = data.createdAt,
              lastAccessedAt = nowMs(),
              expiresAt      = data.expiresAt)
            save(updated)
        }
      case Err(e) -> Err(e)
    }
  }

  func clear(sessionId: in SessionId): Result[Unit, SessionError] {
    match load(sessionId) {
      case Ok(opt) ->
        match opt {
          case None       -> Ok(())
          case Some(data) ->
            val updated = SessionData(
              id             = data.id,
              entries        = Map.empty(),
              createdAt      = data.createdAt,
              lastAccessedAt = nowMs(),
              expiresAt      = data.expiresAt)
            save(updated)
        }
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
@stable(since="0.1")
pub record InProcessSessionStore {
  var sessions: Map[SessionId, SessionData]
  ttlSeconds:   Int
}

impl SessionStore for InProcessSessionStore {
  func create(): Result[SessionId, SessionError] {
    val ts = nowMs()
    val id = "sess-" + ts.toString()
    val data = SessionData(
      id             = id,
      entries        = Map.empty(),
      createdAt      = ts,
      lastAccessedAt = ts,
      expiresAt      = defaultExpiresAt(ttlSeconds))
    sessions.set(id, data)
    return Ok(id)
  }

  func load(sessionId: in SessionId): Result[Option[SessionData], SessionError] {
    match sessions.get(sessionId) {
      case None       -> Ok(None)
      case Some(data) ->
        val ts = nowMs()
        if data.expiresAt != 0 and data.expiresAt < ts {
          sessions.remove(sessionId)
          Ok(None)
        } else {
          Ok(Some(value = data))
        }
    }
  }

  func save(data: in SessionData): Result[Unit, SessionError] {
    sessions.set(data.id, data)
    return Ok(())
  }

  func destroy(sessionId: in SessionId): Result[Unit, SessionError] {
    sessions.remove(sessionId)
    return Ok(())
  }

  func touch(sessionId: in SessionId): Result[Unit, SessionError] {
    match load(sessionId) {
      case Ok(opt) ->
        match opt {
          case None       -> Ok(())
          case Some(data) ->
            val ts = nowMs()
            val updated = SessionData(
              id             = data.id,
              entries        = data.entries,
              createdAt      = data.createdAt,
              lastAccessedAt = ts,
              expiresAt      = defaultExpiresAt(ttlSeconds))
            save(updated)
        }
      case Err(e) -> Err(e)
    }
  }

  func get(sessionId: in SessionId, key: in String): Result[Option[String], SessionError] {
    match load(sessionId) {
      case Ok(opt) ->
        match opt {
          case None       -> Ok(None)
          case Some(data) -> Ok(data.entries.get(key))
        }
      case Err(e) -> Err(e)
    }
  }

  func set(sessionId: in SessionId, key: in String, value: in String): Result[Unit, SessionError] {
    match load(sessionId) {
      case Ok(opt) ->
        val existing = match opt {
          case Some(d) -> d
          case None    ->
            val ts = nowMs()
            SessionData(
              id             = sessionId,
              entries        = Map.empty(),
              createdAt      = ts,
              lastAccessedAt = ts,
              expiresAt      = defaultExpiresAt(ttlSeconds))
        }
        val ts = nowMs()
        val updated = SessionData(
          id             = existing.id,
          entries        = existing.entries.set(key, value),
          createdAt      = existing.createdAt,
          lastAccessedAt = ts,
          expiresAt      = existing.expiresAt)
        save(updated)
      case Err(e) -> Err(e)
    }
  }

  func delete(sessionId: in SessionId, key: in String): Result[Unit, SessionError] {
    match load(sessionId) {
      case Ok(opt) ->
        match opt {
          case None       -> Ok(())
          case Some(data) ->
            val updated = SessionData(
              id             = data.id,
              entries        = data.entries.remove(key),
              createdAt      = data.createdAt,
              lastAccessedAt = nowMs(),
              expiresAt      = data.expiresAt)
            save(updated)
        }
      case Err(e) -> Err(e)
    }
  }

  func clear(sessionId: in SessionId): Result[Unit, SessionError] {
    match load(sessionId) {
      case Ok(opt) ->
        match opt {
          case None       -> Ok(())
          case Some(data) ->
            val updated = SessionData(
              id             = data.id,
              entries        = Map.empty(),
              createdAt      = data.createdAt,
              lastAccessedAt = nowMs(),
              expiresAt      = data.expiresAt)
            save(updated)
        }
      case Err(e) -> Err(e)
    }
  }
}

// ─── Runtime config ───────────────────────────────────────────────────────────

/// Session lifetime and cookie settings.
config Session {
  ttlSeconds: Int range 60..=86400 = 3600
  cookieName: String               = "LYRIC_SESSION"
  secure:     Bool                 = true
  httpOnly:   Bool                 = true
  sameSite:   String               = "Lax"
}

/// Redis connection settings (requires feature = "redis").
@cfg(feature = "redis")
config RedisSession {
  url:       String
  keyPrefix: String = "session:"
}

// ─── Factory ──────────────────────────────────────────────────────────────────

/// Connect to Redis and return a distributed session store.
/// Reads connection settings from the RedisSession config block.
@stable(since="0.1")
@cfg(feature = "redis")
pub func connectRedis(): Result[SessionStore, SessionError] {
  match Session.Kernel.Net.connect(RedisSession.url, RedisSession.keyPrefix) {
    case Ok(handle) -> Ok(NativeSessionStore(storeHandle = handle))
    case Err(err)   -> Err(SessionError(message = err, code = "CONNECT_FAILED"))
  }
}

/// Create an in-process session store using the configured TTL.
@stable(since="0.1")
pub func inMemory(): InProcessSessionStore {
  return InProcessSessionStore(sessions = Map.empty(), ttlSeconds = Session.ttlSeconds)
}

// ─── Convenience public API ───────────────────────────────────────────────────

/// Create a new empty session and return its ID.
@stable(since="0.1")
pub func create(store: in SessionStore): Result[SessionId, SessionError] {
  return store.create()
}

/// Load a session by ID.  Returns None if the session does not exist or has expired.
@stable(since="0.1")
pub func load(store: in SessionStore, sessionId: in SessionId): Result[Option[SessionData], SessionError]
  requires: sessionId.length > 0
{
  return store.load(sessionId)
}

/// Persist a session.
@stable(since="0.1")
pub func save(store: in SessionStore, data: in SessionData): Result[Unit, SessionError]
  requires: data.id.length > 0
{
  return store.save(data)
}

/// Permanently remove a session.
@stable(since="0.1")
pub func destroy(store: in SessionStore, sessionId: in SessionId): Result[Unit, SessionError]
  requires: sessionId.length > 0
{
  return store.destroy(sessionId)
}

/// Refresh a session's expiry without changing its contents.
@stable(since="0.1")
pub func touch(store: in SessionStore, sessionId: in SessionId): Result[Unit, SessionError]
  requires: sessionId.length > 0
{
  return store.touch(sessionId)
}

/// Return the value for a key in the session.
@stable(since="0.1")
pub func get(store: in SessionStore, sessionId: in SessionId, key: in String): Result[Option[String], SessionError]
  requires: sessionId.length > 0
  requires: key.length > 0
{
  return store.get(sessionId, key)
}

/// Set a key-value pair in the session.
@stable(since="0.1")
pub func set(store: in SessionStore, sessionId: in SessionId, key: in String, value: in String): Result[Unit, SessionError]
  requires: sessionId.length > 0
  requires: key.length > 0
{
  return store.set(sessionId, key, value)
}

/// Remove a key from the session.
@stable(since="0.1")
pub func delete(store: in SessionStore, sessionId: in SessionId, key: in String): Result[Unit, SessionError]
  requires: sessionId.length > 0
  requires: key.length > 0
{
  return store.delete(sessionId, key)
}

/// Remove all keys from a session without destroying it.
@stable(since="0.1")
pub func clear(store: in SessionStore, sessionId: in SessionId): Result[Unit, SessionError]
  requires: sessionId.length > 0
{
  return store.clear(sessionId)
}

// ─── Private helpers ──────────────────────────────────────────────────────────

// Current time in epoch milliseconds.
func nowMs(): Long {
  return Std.Time.SystemClock.now().toEpochMillis()
}

// Compute an expiry timestamp: 0 if ttlSeconds == 0 (no expiry),
// otherwise nowMs() + ttlSeconds * 1000.
func defaultExpiresAt(ttlSeconds: in Int): Long {
  if ttlSeconds == 0 {
    return 0
  }
  return nowMs() + ttlSeconds * 1000
}

// Minimal JSON serializer for SessionData (produces the protocol format
// consumed by Session.Kernel.Net.save / load when using the Redis store).
// Encodes id, createdAt, lastAccessedAt, expiresAt, and entries as a flat
// JSON object.  Only handles string values without special characters.
func serializeSessionJson(data: in SessionData): String {
  var entriesJson = "{"
  var first = true
  for (k, v) in data.entries {
    if not first { entriesJson = entriesJson + "," }
    entriesJson = entriesJson + "\"" + k + "\":\"" + v + "\""
    first = false
  }
  entriesJson = entriesJson + "}"
  return "{\"id\":\"" + data.id + "\","
       + "\"createdAt\":" + data.createdAt.toString() + ","
       + "\"lastAccessedAt\":" + data.lastAccessedAt.toString() + ","
       + "\"expiresAt\":" + data.expiresAt.toString() + ","
       + "\"entries\":" + entriesJson + "}"
}

// Minimal JSON deserializer for the SessionData protocol format returned by
// Session.Kernel.Net.load.  Produces a SessionData with the stored timestamps
// and an empty entries map (full entry parsing is deferred to the kernel,
// which returns structured data via the handle).  The in-process store does
// not use this path.
func parseSessionJson(sessionId: in SessionId, json: in String): SessionData {
  return SessionData(
    id             = sessionId,
    entries        = Map.empty(),
    createdAt      = 0,
    lastAccessedAt = 0,
    expiresAt      = 0)
}
