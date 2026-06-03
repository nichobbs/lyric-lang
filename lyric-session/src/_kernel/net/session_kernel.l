//! Session.Kernel.Net — Redis extern boundary for distributed session storage.
//!
//! Bridges the Session package to StackExchange.Redis via the
//! `Lyric.Session.RedisStore` host shim (bootstrap/src/Lyric.Session.Host/):
//!   - connect()  — open a connection pool and return a store handle
//!   - create()   — allocate a new session with the given TTL
//!   - load()     — fetch a session as serialised JSON (empty string = not found)
//!   - save()     — persist serialised session JSON (preserves TTL via KeepTtl=true)
//!   - destroy()  — permanently delete a session
//!   - touch()    — refresh the session TTL without changing its contents
//!
//! Phase-1 host-shim path (#733).  The `extern package StackExchange.Redis`
//! block form used in the original restoration (PR #987) is metadata-only
//! — the emitter does not emit IL for those declarations, so any user
//! code calling through them would fail at runtime.  This file uses the
//! `@externTarget("Lyric.Session.RedisStore.<method>")` form instead,
//! which the emitter resolves to a real static-method call at codegen
//! time.  The shim translates StackExchange.Redis exceptions into the
//! Lyric `Result[T, String]` convention so failures never escape the
//! language-level boundary.
//!
//! Only active when compiled with feature = "redis".
//! See docs/14-native-stdlib-plan.md for the kernel boundary contract.

@cfg(feature = "redis")
package Session.Kernel.Net

import Std.Core

// ─── Redis session backend (host-shim bindings) ───────────────────────────────

/// Open a connection pool to the Redis server at `url`.
/// `keyPrefix` is prepended to every session key (e.g. "session:").
/// Returns an opaque handle used in subsequent calls.
@axiom("Lyric.Session.RedisStore.connect — StackExchange.Redis ConnectionMultiplexer.Connect + per-process handle registration")
@externTarget("Lyric.Session.RedisStore.connect")
@stable(since="0.1")
pub func connect(url: in String, keyPrefix: in String): Result[Int, String]
  requires: url.length > 0
  = ()

/// Allocate a new empty session.
/// `ttlSeconds` sets the Redis key TTL; 0 means no expiry.
/// Returns the new session ID (a UUID string).
@axiom("Lyric.Session.RedisStore.create — StringSet new UUID key with TTL")
@externTarget("Lyric.Session.RedisStore.create")
@stable(since="0.1")
pub func create(storeHandle: in Int, ttlSeconds: in Int): Result[String, String]
  requires: ttlSeconds >= 0
  = ()

/// Fetch the serialised JSON for the given session ID.
/// Returns an empty string if the session does not exist or has expired.
@axiom("Lyric.Session.RedisStore.load — StringGet; '' on miss")
@externTarget("Lyric.Session.RedisStore.load")
@stable(since="0.1")
pub func load(storeHandle: in Int, sessionId: in String): Result[String, String]
  requires: sessionId.length > 0
  = ()

/// Persist the serialised session JSON.  Overwrites any existing entry,
/// preserving the original TTL (StringSet with keepTtl=true).  The
/// `sessionId` is passed explicitly so the host shim can compute the
/// Redis key directly without parsing the JSON payload.
@axiom("Lyric.Session.RedisStore.save — StringSet keepTtl=true")
@externTarget("Lyric.Session.RedisStore.save")
@stable(since="0.1")
pub func save(storeHandle: in Int, sessionId: in String, sessionJson: in String): Result[Unit, String]
  requires: sessionId.length > 0
  requires: sessionJson.length > 0
  = ()

/// Permanently delete a session.  No-op if the key is absent.
@axiom("Lyric.Session.RedisStore.destroy — KeyDelete")
@externTarget("Lyric.Session.RedisStore.destroy")
@stable(since="0.1")
pub func destroy(storeHandle: in Int, sessionId: in String): Result[Unit, String]
  requires: sessionId.length > 0
  = ()

/// Refresh the session's TTL without changing its content.
/// `ttlSeconds = 0` leaves the TTL unchanged.
@axiom("Lyric.Session.RedisStore.touch — KeyExpire; ttlSeconds=0 is a no-op")
@externTarget("Lyric.Session.RedisStore.touch")
@stable(since="0.1")
pub func touch(storeHandle: in Int, sessionId: in String, ttlSeconds: in Int): Result[Unit, String]
  requires: sessionId.length > 0
  requires: ttlSeconds >= 0
  = ()
