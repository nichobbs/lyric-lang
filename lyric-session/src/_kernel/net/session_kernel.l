//! Session.Kernel.Net — direct BCL extern boundary for Redis-backed session
//! storage via StackExchange.Redis.
//!
//! Replaces the F# host shim (`Lyric.Session.RedisStore` in
//! `bootstrap/src/Lyric.Session.Host/RedisStore.fs`) with native Lyric
//! `@externTarget` bindings (#1777).
//!
//! ## BREAKING CHANGE: session ID format (#3022)
//!
//! Session IDs are now generated via `Std.Uuid.newUuid()` / `uuidToString()`,
//! which produces **hyphenated UUID** format (e.g.
//! `550e8400-e29b-41d4-a716-446655440000`).  The old F# host shim used
//! `Guid.NewGuid().ToString("N")`, which produced **no-dash hex** format
//! (e.g. `550e8400e29b41d4a716446655440000`).
//!
//! Applications upgrading from the F# shim will have existing sessions stored
//! in Redis under the old no-dash keys.  After the upgrade the new code looks
//! up sessions under hyphenated keys — all pre-upgrade sessions will appear as
//! "not found," effectively logging out every active user.
//!
//! **Migration**: flush the Redis session namespace before deploying this
//! version (e.g. `redis-cli --scan --pattern '<keyPrefix>*' | xargs redis-cli del`),
//! or accept a one-time forced re-login for all active users at deployment time.
//!
//! ## Design changes vs the old shim path
//!
//!   * Handle type — the opaque `Int` store handle is replaced by a
//!     `RedisStoreHandle` record `{ db: RedisDb, keyPrefix: String }`.
//!     The F# shim maintained an in-process `ConcurrentDictionary<int,
//!     RedisHandle>`; this record IS the handle, eliminating the registry
//!     entirely.  `session.l` stores `RedisStoreHandle` in `NativeSessionStore`
//!     and passes it back to each kernel call.
//!
//!   * Session IDs — see BREAKING CHANGE above.
//!
//!   * `Nullable<TimeSpan>` — `default(): NullableTimeSpan` produces the null
//!     (no-TTL) form; `wrapNullableTs(timeSpanFromSecs(n.toDouble()))` produces
//!     the non-null form.  The F# bootstrap emitter emits `initobj` for
//!     `default()` on value-type extern types and `newobj` for `..ctor` calls.
//!
//! Only active when compiled with `feature = "dotnet"`.
@axiom("StackExchange.Redis.ConnectionMultiplexer / IDatabase conform to StackExchange.Redis 2.x documented contracts")
@cfg(feature = "dotnet")
package Session.Kernel.Net

import Std.Core
import Std.Uuid

// ── BCL / StackExchange.Redis extern types ────────────────────────────────────
extern type Multiplexer = "StackExchange.Redis.IConnectionMultiplexer"

extern type RedisDb = "StackExchange.Redis.IDatabase"

extern type RedisKeyT = "StackExchange.Redis.RedisKey"

extern type RedisValueT = "StackExchange.Redis.RedisValue"

// For TTL: `System.TimeSpan` (value type) and its nullable wrapper.
extern type TimeSpanT = "System.TimeSpan"

// `System.Nullable`1[System.TimeSpan]` is a value type (struct).
// `default(): NullableTimeSpan` → `initobj` (null / HasValue=false).
// `wrapNullableTs(ts)` → `newobj Nullable<TimeSpan>::.ctor(TimeSpan)`.
extern type NullableTimeSpan = "System.Nullable`1[System.TimeSpan]"

// StackExchange.Redis enum types: default value 0 is the "no-flag" case.
// `When.Always = 0`, `CommandFlags.None = 0`, `ExpireWhen.Always = 0`.
extern type WhenEnum = "StackExchange.Redis.When"

extern type CommandFlagsT = "StackExchange.Redis.CommandFlags"

// For the `TextWriter log` param of `ConnectionMultiplexer.Connect`; pass null.
extern type TextWriter = "System.IO.TextWriter"

// For the `Object asyncState` param of `IConnectionMultiplexer.GetDatabase`.
extern type AnyObj = "System.Object"

// ── Primitive extern functions ────────────────────────────────────────────────
// ConnectionMultiplexer.Connect(string configuration, TextWriter log)
// Static; pass null TextWriter to suppress log output.
@externStatic
@externTarget("StackExchange.Redis.ConnectionMultiplexer.Connect")
func connectMultiplexer(configuration: in String, log: in TextWriter): Multiplexer = ()

// IConnectionMultiplexer.GetDatabase(int db, object asyncState)
// Use db=-1 (default DB) and asyncState=null.
@externTarget("StackExchange.Redis.IConnectionMultiplexer.GetDatabase")
func getDatabase(mux: in Multiplexer, db: in Int, asyncState: in AnyObj): RedisDb = ()

// String → RedisKey implicit conversion (StackExchange.Redis.RedisKey.op_Implicit(string)).
@externStatic
@externTarget("StackExchange.Redis.RedisKey.op_Implicit")
func toRedisKey(s: in String): RedisKeyT = ()

// String → RedisValue implicit conversion (StackExchange.Redis.RedisValue.op_Implicit(string)).
@externStatic
@externTarget("StackExchange.Redis.RedisValue.op_Implicit")
func toRedisValue(s: in String): RedisValueT = ()

// StringSet(key, value, Nullable<TimeSpan> expiry, When when): used by `create`.
// When.Always = 0 = default(); pass default() for `when`.
@externTarget("StackExchange.Redis.IDatabase.StringSet")
func strSetCreate(
  db: in RedisDb,
  key: in RedisKeyT,
  value: in RedisValueT,
  expiry: in NullableTimeSpan,
  setWhen: in WhenEnum,
): Bool = ()

// StringSet(key, value, Nullable<TimeSpan> expiry, bool keepTtl, When when, CommandFlags flags): used by `save`.
// Pass null expiry, keepTtl=true, default When and CommandFlags.
@externTarget("StackExchange.Redis.IDatabase.StringSet")
func strSetKeepTtl(
  db: in RedisDb,
  key: in RedisKeyT,
  value: in RedisValueT,
  expiry: in NullableTimeSpan,
  keepTtl: in Bool,
  setWhen: in WhenEnum,
  flags: in CommandFlagsT,
): Bool = ()

// StringGet(key, CommandFlags flags): used by `load`.
@externTarget("StackExchange.Redis.IDatabase.StringGet")
func strGet(db: in RedisDb, key: in RedisKeyT, flags: in CommandFlagsT): RedisValueT = ()

// KeyDelete(key, CommandFlags flags): used by `destroy`.
@externTarget("StackExchange.Redis.IDatabase.KeyDelete")
func keyDel(db: in RedisDb, key: in RedisKeyT, flags: in CommandFlagsT): Bool = ()

// KeyExpire(key, Nullable<TimeSpan> expiry, CommandFlags flags): used by `touch`.
@externTarget("StackExchange.Redis.IDatabase.KeyExpire")
func keyExpire(db: in RedisDb, key: in RedisKeyT, expiry: in NullableTimeSpan, flags: in CommandFlagsT): Bool = ()

// TimeSpan.FromSeconds(double value): constructs a non-null TimeSpan.
@externStatic
@externTarget("System.TimeSpan.FromSeconds")
func timeSpanFromSecs(secs: in Double): TimeSpanT = ()

// Nullable<TimeSpan> constructor: wraps a TimeSpan in a non-null nullable.
@externTarget("System.Nullable`1[System.TimeSpan]..ctor")
func wrapNullableTs(ts: in TimeSpanT): NullableTimeSpan = ()

// RedisValue.IsNullOrEmpty (get_IsNullOrEmpty): true if the value is null or empty.
@externTarget("StackExchange.Redis.RedisValue.get_IsNullOrEmpty")
func redisValueIsNull(rv: in RedisValueT): Bool = ()

// RedisValue.ToString(): extract the string value from a RedisValue.
@externTarget("StackExchange.Redis.RedisValue.ToString")
func redisValueToString(rv: in RedisValueT): String = ()

// ── Opaque store handle ───────────────────────────────────────────────────────
/// Opaque handle returned by `connect` and consumed by every other kernel
/// function.  Holds the `IDatabase` reference (which transitively keeps the
/// `IConnectionMultiplexer` alive) and the key prefix for session keys.
pub record RedisStoreHandle {
  db: RedisDb
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
@axiom("StackExchange.Redis.ConnectionMultiplexer.Connect opens a managed connection pool; GetDatabase returns a lightweight IDatabase proxy")
@stable(since = "0.1")
pub func connect(url: in String, keyPrefix: in String): Result[RedisStoreHandle, String]
  requires: url.length > 0
{
  val nullLog: TextWriter = default()
  try {
    val mux = connectMultiplexer(url, nullLog)
    val nullState: AnyObj = default()
    val db = getDatabase(mux, -1, nullState)
    Ok(RedisStoreHandle(db = db, keyPrefix = keyPrefix))
  } catch Bug as b {
    Err(b.message)
  }
}

/// Allocate a new empty session.
/// `ttlSeconds` sets the Redis key TTL; 0 means no expiry.
/// Returns the new session ID (a UUID string).
@axiom("IDatabase.StringSet with a freshly generated UUID key; TTL applied when ttlSeconds > 0")
@stable(since = "0.1")
pub func kernelCreate(handle: in RedisStoreHandle, ttlSeconds: in Int): Result[String, String]
  requires: ttlSeconds >= 0
{
  val sessionId = uuidToString(newUuid())
  val key = toRedisKey(sessionKey(handle, sessionId))
  val val_ = toRedisValue("{}")
  val expiry: NullableTimeSpan = if ttlSeconds > 0 {
    wrapNullableTs(timeSpanFromSecs(ttlSeconds.toDouble()))
  } else {
    default()
  }
  val when_: WhenEnum = default()
  try {
    val _ = strSetCreate(handle.db, key, val_, expiry, when_)
    Ok(sessionId)
  } catch Bug as b {
    Err(b.message)
  }
}

/// Fetch the serialised JSON for the given session ID.
/// Returns an empty string if the session does not exist or has expired.
@axiom("IDatabase.StringGet; empty string on key-miss or expiry")
@stable(since = "0.1")
pub func kernelLoad(handle: in RedisStoreHandle, sessionId: in String): Result[String, String]
  requires: sessionId.length > 0
{
  val key = toRedisKey(sessionKey(handle, sessionId))
  val flags: CommandFlagsT = default()
  try {
    val rv = strGet(handle.db, key, flags)
    if redisValueIsNull(rv) {
      Ok("")
    } else {
      Ok(redisValueToString(rv))
    }
  } catch Bug as b {
    Err(b.message)
  }
}

/// Persist the serialised session JSON, preserving the original TTL.
@axiom("IDatabase.StringSet with keepTtl=true; null expiry so StackExchange.Redis honours the key's existing TTL")
@stable(since = "0.1")
pub func kernelSave(handle: in RedisStoreHandle, sessionId: in String, sessionJson: in String): Result[Unit, String]
  requires: sessionId.length > 0
  requires: sessionJson.length > 0
{
  val key = toRedisKey(sessionKey(handle, sessionId))
  val val_ = toRedisValue(sessionJson)
  val nullExpiry: NullableTimeSpan = default()
  val when_: WhenEnum = default()
  val flags: CommandFlagsT = default()
  try {
    val _ = strSetKeepTtl(handle.db, key, val_, nullExpiry, true, when_, flags)
    Ok(())
  } catch Bug as b {
    Err(b.message)
  }
}

/// Permanently delete a session.  No-op if the key is absent.
@axiom("IDatabase.KeyDelete; silent no-op on missing key")
@stable(since = "0.1")
pub func kernelDestroy(handle: in RedisStoreHandle, sessionId: in String): Result[Unit, String]
  requires: sessionId.length > 0
{
  val key = toRedisKey(sessionKey(handle, sessionId))
  val flags: CommandFlagsT = default()
  try {
    val _ = keyDel(handle.db, key, flags)
    Ok(())
  } catch Bug as b {
    Err(b.message)
  }
}

/// Refresh the session's TTL without changing its content.
/// `ttlSeconds = 0` is a no-op.
@axiom("IDatabase.KeyExpire; ttlSeconds=0 leaves TTL unchanged")
@stable(since = "0.1")
pub func kernelTouch(handle: in RedisStoreHandle, sessionId: in String, ttlSeconds: in Int): Result[Unit, String]
  requires: sessionId.length > 0
  requires: ttlSeconds >= 0
{
  if ttlSeconds == 0 {
    return Ok(())
  }
  val key = toRedisKey(sessionKey(handle, sessionId))
  val expiry = wrapNullableTs(timeSpanFromSecs(ttlSeconds.toDouble()))
  val flags: CommandFlagsT = default()
  try {
    val _ = keyExpire(handle.db, key, expiry, flags)
    Ok(())
  } catch Bug as b {
    Err(b.message)
  }
}
