//! Session.Kernel.Jvm — JVM extern boundary for distributed session storage.
//!
//! JVM implementation of the same Redis-backed contract as
//! `Session.Kernel.Net`.  Pure Lyric over the JVM auto-FFI against
//! `io.lettuce:lettuce-core`'s synchronous command API — no F#/Java shim
//! classes, no `extern package` (that mechanism is a confirmed no-op in
//! both the type checker and MSIL/JVM codegen; see docs/03-decision-log.md
//! D-progress-625/#5324 and the elimination precedent in
//! `lyric-feature-flags` D-progress-627). `RedisClient.create(url)` opens
//! a connection pool; `.connect()` + `.sync()` yield the synchronous
//! `RedisCommands<String, String>` interface, matched against the
//! *actual* Lettuce 6.8.2 bytecode (verified via `javap` against the
//! restored Maven artifact, not guessed from documentation).
//!
//! There is no host-backed in-memory store on this target: the earlier
//! `lyric.session.InMemoryStore` extern-package block declared here was
//! dead code (an `extern package`, itself a no-op FFI mechanism, gating a
//! store that `session.l`'s `InProcessSessionStore` — a pure-Lyric
//! `Map[String, SessionData]` — never called on either target). Removed
//! rather than ported, matching the `Flags.Registry` precedent
//! (D-progress-627): a plain `Map` needs no BCL/JDK object reference at
//! all, so `InProcessSessionStore` already serves `dotnet` and `jvm`
//! identically with no kernel boundary.
//!
//! Only active when compiled with feature = "jvm".
//! See docs/14-native-stdlib-plan.md for the kernel boundary contract.
@axiom("io.lettuce.core.RedisClient / StatefulRedisConnection / RedisCommands (io.lettuce:lettuce-core 6.8.x) conform to their documented Maven contracts")
@cfg(feature = "jvm")
package Session.Kernel.Jvm

import Std.Core
import Std.Collections
import Std.Uuid

// ── Lettuce extern types (io.lettuce:lettuce-core, resolved via [maven]) ─────
extern type LettuceClient = "io.lettuce.core.RedisClient"

extern type LettuceConnection = "io.lettuce.core.api.StatefulRedisConnection"

extern type LettuceCommands = "io.lettuce.core.api.sync.RedisCommands"

extern type LettuceSetArgs = "io.lettuce.core.SetArgs"

// ── Opaque store handle ───────────────────────────────────────────────────────
/// Opaque handle returned by `connect` and consumed by every other kernel
/// function.  Holds the synchronous `RedisCommands` facade (which
/// transitively keeps the `StatefulRedisConnection` / `RedisClient` alive)
/// and the key prefix for session keys — the JVM analog of
/// `Session.Kernel.Net.RedisStoreHandle`.
pub record RedisStoreHandle {
  commands: LettuceCommands
  keyPrefix: String
}

// ── Helper: compute the full Redis key for a session ────────────────────────
func sessionKey(h: in RedisStoreHandle, sessionId: in String): String {
  h.keyPrefix + sessionId
}

// ── Public kernel entry points ────────────────────────────────────────────────
/// Open a connection pool to the Redis server at `url`.
/// `keyPrefix` is prepended to every session key (e.g. "session:").
/// Returns a `RedisStoreHandle` used in subsequent calls.
@axiom("RedisClient.create(url).connect().sync() opens a managed connection and returns its synchronous command facade")
@stable(since = "0.1")
pub func connect(url: in String, keyPrefix: in String): Result[RedisStoreHandle, String]
  requires: url.length > 0
{
  try {
    val client = LettuceClient.create(url)
    val conn = client.connect()
    val commands = conn.sync()
    Ok(RedisStoreHandle(commands = commands, keyPrefix = keyPrefix))
  } catch Bug as b {
    Err(b.message)
  }
}

/// Allocate a new empty session.
/// `ttlSeconds` sets the Redis key TTL; 0 means no expiry.
/// Returns the new session ID (a UUID string).
@axiom("RedisCommands.setex/set with a freshly generated UUID key; TTL applied when ttlSeconds > 0")
@stable(since = "0.1")
pub func kernelCreate(handle: in RedisStoreHandle, ttlSeconds: in Int): Result[String, String]
  requires: ttlSeconds >= 0
{
  val sessionId = uuidToString(newUuid())
  val key = sessionKey(handle, sessionId)
  try {
    if ttlSeconds > 0 {
      val _ = handle.commands.setex(key, ttlSeconds.toLong(), "{}")
      Ok(sessionId)
    } else {
      val _ = handle.commands.set(key, "{}")
      Ok(sessionId)
    }
  } catch Bug as b {
    Err(b.message)
  }
}

/// Fetch the serialised JSON for the given session ID.
/// Returns an empty string if the session does not exist or has expired.
@axiom("RedisCommands.get; empty string on key-miss (Lettuce returns null) or expiry")
@stable(since = "0.1")
pub func kernelLoad(handle: in RedisStoreHandle, sessionId: in String): Result[String, String]
  requires: sessionId.length > 0
{
  val key = sessionKey(handle, sessionId)
  try {
    val v = handle.commands.get(key)
    match v {
      case null -> Ok("")
      case _ -> Ok(v)
    }
  } catch Bug as b {
    Err(b.message)
  }
}

/// Persist the serialised session JSON, preserving the original TTL.
@axiom("RedisCommands.set with SetArgs.keepttl() so Lettuce honours the key's existing TTL")
@stable(since = "0.1")
pub func kernelSave(handle: in RedisStoreHandle, sessionId: in String, sessionJson: in String): Result[Unit, String]
  requires: sessionId.length > 0
  requires: sessionJson.length > 0
{
  val key = sessionKey(handle, sessionId)
  try {
    val args = LettuceSetArgs.new()
    val keepTtlArgs = args.keepttl()
    val _ = handle.commands.set(key, sessionJson, keepTtlArgs)
    Ok(())
  } catch Bug as b {
    Err(b.message)
  }
}

/// Permanently delete a session.  No-op if the key is absent.
@axiom("RedisCommands.del; silent no-op on missing key")
@stable(since = "0.1")
pub func kernelDestroy(handle: in RedisStoreHandle, sessionId: in String): Result[Unit, String]
  requires: sessionId.length > 0
{
  val key = sessionKey(handle, sessionId)
  // `RedisKeyCommands.del(K...)` is a real Java varargs method — its
  // bytecode descriptor is `([Ljava/lang/Object;)Ljava/lang/Long;`, a
  // single array parameter.  Java's varargs call-site sugar (auto-wrapping
  // a single argument into a 1-element array) is a javac-only convenience
  // with no bytecode-level counterpart, so the array must be built
  // explicitly here; a bare `del(key)` argument-count-matches but
  // descriptor-mismatches (`Ljava/lang/String;` vs `[Ljava/lang/Object;`)
  // and fails auto-FFI resolution.
  val keys: List[String] = newList()
  keys.add(key)
  try {
    val _ = handle.commands.del(keys.toArray())
    Ok(())
  } catch Bug as b {
    Err(b.message)
  }
}

/// Refresh the session's TTL without changing its content.
/// `ttlSeconds = 0` is a no-op.
@axiom("RedisCommands.expire; ttlSeconds=0 leaves TTL unchanged")
@stable(since = "0.1")
pub func kernelTouch(handle: in RedisStoreHandle, sessionId: in String, ttlSeconds: in Int): Result[Unit, String]
  requires: sessionId.length > 0
  requires: ttlSeconds >= 0
{
  if ttlSeconds == 0 {
    return Ok(())
  }
  val key = sessionKey(handle, sessionId)
  try {
    val _ = handle.commands.expire(key, ttlSeconds.toLong())
    Ok(())
  } catch Bug as b {
    Err(b.message)
  }
}
