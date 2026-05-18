/// Session.Kernel.Jvm — JVM extern boundary for distributed session storage.
///
/// JVM implementation of the same contract as Session.Kernel.Net.  All Redis
/// operations resolve through `lyric.session.RedisStore`, which the JVM runtime
/// backs with Lettuce (`io.lettuce.core.RedisClient`).  In-memory operations
/// resolve through `lyric.session.InMemoryStore`, backed by
/// `java.util.concurrent.ConcurrentHashMap`.
///
/// The public re-export functions are identical to Session.Kernel.Net so that
/// the `Session` package can call either kernel through the target-gated
/// dispatcher helpers in session.l without reshaping.
///
/// Only active when compiled with feature = "jvm" (Phase 6).
/// See docs/14-native-stdlib-plan.md for the kernel boundary contract.

@cfg(feature = "jvm")
package Session.Kernel.Jvm

import Std.Core

// ─── Redis session backend ────────────────────────────────────────────────────

@cfg(feature = "redis")
@axiom("io.lettuce.core.RedisClient via lyric.session.RedisStore for distributed session storage")
extern package lyric.session.RedisStore {
  /// Open a connection pool to the Redis server at `url`.
  /// `keyPrefix` is prepended to every session key (e.g. "session:").
  /// Returns an opaque handle used in subsequent calls.
  pub func connect(url: String, keyPrefix: String): Result[Int, String]
    requires: url.length > 0

  /// Allocate a new empty session.
  /// `ttlSeconds` sets the key TTL; 0 means no expiry.
  /// Returns the new session ID (a UUID string).
  pub func create(storeHandle: Int, ttlSeconds: Int): Result[String, String]
    requires: ttlSeconds >= 0

  /// Fetch the serialised JSON for the given session ID.
  /// Returns an empty string if the session does not exist or has expired.
  pub func load(storeHandle: Int, sessionId: String): Result[String, String]
    requires: sessionId.length > 0

  /// Persist the serialised session JSON.  Overwrites any existing entry.
  pub func save(storeHandle: Int, sessionJson: String): Result[Unit, String]
    requires: sessionJson.length > 0

  /// Permanently delete a session.  No-op if the key is absent.
  pub func destroy(storeHandle: Int, sessionId: String): Result[Unit, String]
    requires: sessionId.length > 0

  /// Refresh the session's TTL without changing its content.
  /// `ttlSeconds = 0` leaves the TTL unchanged.
  pub func touch(storeHandle: Int, sessionId: String, ttlSeconds: Int): Result[Unit, String]
    requires: sessionId.length > 0
    requires: ttlSeconds >= 0
}

// ─── In-memory session backend ────────────────────────────────────────────────

@cfg(feature = "inmemory")
@axiom("lyric.session.InMemoryStore backed by java.util.concurrent.ConcurrentHashMap")
extern package lyric.session.InMemoryStore {
  /// Open an in-memory session store.  Returns an opaque handle.
  pub func open(): Int

  /// Allocate a new empty session.
  /// `ttlSeconds` sets the logical TTL; 0 means no expiry.
  /// Returns the new session ID (a UUID string).
  pub func create(storeHandle: Int, ttlSeconds: Int): Result[String, String]
    requires: ttlSeconds >= 0

  /// Fetch the serialised JSON for the given session ID.
  /// Returns an empty string if the session does not exist or has expired.
  pub func load(storeHandle: Int, sessionId: String): Result[String, String]
    requires: sessionId.length > 0

  /// Persist the serialised session JSON.  Overwrites any existing entry.
  pub func save(storeHandle: Int, sessionJson: String): Result[Unit, String]
    requires: sessionJson.length > 0

  /// Permanently delete a session.  No-op if the key is absent.
  pub func destroy(storeHandle: Int, sessionId: String): Result[Unit, String]
    requires: sessionId.length > 0

  /// Refresh the session's logical TTL without changing its content.
  pub func touch(storeHandle: Int, sessionId: String, ttlSeconds: Int): Result[Unit, String]
    requires: sessionId.length > 0
    requires: ttlSeconds >= 0
}

// ─── Re-export wrappers (Redis) ───────────────────────────────────────────────

/// Open a Redis connection pool for session storage.
@cfg(feature = "redis")
@stable(since="0.1")
pub func connect(url: in String, keyPrefix: in String): Result[Int, String]
  requires: url.length > 0
{
  return lyric.session.RedisStore.connect(url, keyPrefix)
}

/// Allocate a new session and return its ID (Redis backend).
@cfg(feature = "redis")
@stable(since="0.1")
pub func create(storeHandle: in Int, ttlSeconds: in Int): Result[String, String]
  requires: ttlSeconds >= 0
{
  return lyric.session.RedisStore.create(storeHandle, ttlSeconds)
}

/// Fetch a session as serialised JSON (Redis backend).  Returns "" if not found.
@cfg(feature = "redis")
@stable(since="0.1")
pub func load(storeHandle: in Int, sessionId: in String): Result[String, String]
  requires: sessionId.length > 0
{
  return lyric.session.RedisStore.load(storeHandle, sessionId)
}

/// Persist serialised session JSON (Redis backend).
@cfg(feature = "redis")
@stable(since="0.1")
pub func save(storeHandle: in Int, sessionJson: in String): Result[Unit, String]
  requires: sessionJson.length > 0
{
  return lyric.session.RedisStore.save(storeHandle, sessionJson)
}

/// Permanently delete a session (Redis backend).
@cfg(feature = "redis")
@stable(since="0.1")
pub func destroy(storeHandle: in Int, sessionId: in String): Result[Unit, String]
  requires: sessionId.length > 0
{
  return lyric.session.RedisStore.destroy(storeHandle, sessionId)
}

/// Refresh a session's TTL without changing its content (Redis backend).
@cfg(feature = "redis")
@stable(since="0.1")
pub func touch(storeHandle: in Int, sessionId: in String, ttlSeconds: in Int): Result[Unit, String]
  requires: sessionId.length > 0
  requires: ttlSeconds >= 0
{
  return lyric.session.RedisStore.touch(storeHandle, sessionId, ttlSeconds)
}
