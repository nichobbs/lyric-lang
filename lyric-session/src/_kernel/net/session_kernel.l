// Session.Kernel.Net — Redis extern boundary for distributed session storage.
//
// Bridges the Session package to StackExchange.Redis:
//   - connect()  — open a connection pool and return a store handle
//   - create()   — allocate a new session with the given TTL
//   - load()     — fetch a session as serialised JSON (empty string = not found)
//   - save()     — persist serialised session JSON
//   - destroy()  — permanently delete a session
//   - touch()    — refresh the session TTL without changing its contents
//
// Only active when compiled with feature = "redis".
// See docs/14-native-stdlib-plan.md for the kernel boundary contract.

@cfg(feature = "redis")
package Session.Kernel.Net

import Std.Core

// ─── Redis session backend ────────────────────────────────────────────────────

@axiom("StackExchange.Redis for distributed session storage")
extern package StackExchange.Redis {
  /// Open a connection pool to the Redis server at `url`.
  /// `keyPrefix` is prepended to every session key (e.g. "session:").
  /// Returns an opaque handle used in subsequent calls.
  pub func connect(url: String, keyPrefix: String): Result[Int, String]
    requires: url.length > 0

  /// Allocate a new empty session.
  /// `ttlSeconds` sets the Redis key TTL; 0 means no expiry.
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

// ─── Re-export wrappers ───────────────────────────────────────────────────────

/// Open a Redis connection pool for session storage.
@stable(since="0.1")
pub func connect(url: in String, keyPrefix: in String): Result[Int, String]
  requires: url.length > 0
{
  return StackExchange.Redis.connect(url, keyPrefix)
}

/// Allocate a new session and return its ID.
@stable(since="0.1")
pub func create(storeHandle: in Int, ttlSeconds: in Int): Result[String, String]
  requires: ttlSeconds >= 0
{
  return StackExchange.Redis.create(storeHandle, ttlSeconds)
}

/// Fetch a session as serialised JSON.  Returns "" if not found.
@stable(since="0.1")
pub func load(storeHandle: in Int, sessionId: in String): Result[String, String]
  requires: sessionId.length > 0
{
  return StackExchange.Redis.load(storeHandle, sessionId)
}

/// Persist serialised session JSON.
@stable(since="0.1")
pub func save(storeHandle: in Int, sessionJson: in String): Result[Unit, String]
  requires: sessionJson.length > 0
{
  return StackExchange.Redis.save(storeHandle, sessionJson)
}

/// Permanently delete a session.
@stable(since="0.1")
pub func destroy(storeHandle: in Int, sessionId: in String): Result[Unit, String]
  requires: sessionId.length > 0
{
  return StackExchange.Redis.destroy(storeHandle, sessionId)
}

/// Refresh a session's TTL without changing its content.
@stable(since="0.1")
pub func touch(storeHandle: in Int, sessionId: in String, ttlSeconds: in Int): Result[Unit, String]
  requires: sessionId.length > 0
  requires: ttlSeconds >= 0
{
  return StackExchange.Redis.touch(storeHandle, sessionId, ttlSeconds)
}
