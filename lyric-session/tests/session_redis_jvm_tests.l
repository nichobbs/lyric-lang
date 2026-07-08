//! tests/session_redis_jvm_tests.l — CRUD integration suite for the
//! Redis-backed `NativeSessionStore`, exercised through the public
//! `Session.connectRedis()` factory.
//!
//! Not `@cfg`-gated to a single platform: `lyric test`'s `[project.tests]`
//! runner does not apply file-level `@cfg` erasure to test sources (each
//! test file is fed straight to `Lyric.TestSynth` and bundled via
//! `emitProject`, bypassing the manifest-level `Cfg`/`CfgGate` passes), so
//! `connectRedis()` here transparently resolves to whichever backend
//! (`Session.Kernel.Net`'s StackExchange.Redis, or `Session.Kernel.Jvm`'s
//! Lettuce) is active for the current `--target`/`--features` build —
//! this file is the shared integration suite for both.
//!
//! Requires a reachable Redis server named by
//! `LYRIC_CONFIG_SESSION_REDISSESSION_URL` (dotnet: StackExchange.Redis
//! config-string form, e.g. `127.0.0.1:6379`; jvm: a `redis://` URI, e.g.
//! `redis://127.0.0.1:6379`, per Lettuce's `RedisURI` parser); every test
//! skips (rather than failing) when that env var is unset, so a plain
//! `lyric test --manifest lyric-session/lyric.toml` still exits green in
//! an environment with no Redis server (mirroring the "framework-level,
//! requires a live connection" carve-out already documented for the
//! .NET side in `sensitive_url_tests.l`).
//!
//! Run against `--target jvm`: `lyric test --target jvm
//! --no-default-features --features jvm` builds correctly, but (as of this
//! writing) `lyric test`'s JVM runner execs the compiled test jar as a
//! plain `java -jar test.jar` with no `-cp`/`--module-path` for the
//! `[maven]`-restored Lettuce jars — a pre-existing gap shared with `lyric
//! run --target jvm` (`cli_run.l`), not specific to this library — so a
//! Maven-dependent JVM test can only be exercised by manually running the
//! compiled jar with the classpath from `target/restore/jvm-classpath.txt`
//! appended (see this library's README for the exact command).  See
//! docs/03-decision-log.md for the tracked follow-up.
@test_module
package Session.SessionRedisJvmTests

import Std.Core
import Std.Testing
import Std.Environment as Env
import Session as Session

// True when a Redis URL has been configured for this run.  Every test
// below no-ops (an `Ok`-shaped, assertion-free early return) rather than
// failing when this is false, so the suite is opt-in: it only exercises
// real Redis when a live server has been wired up (see the module header).
func redisConfigured(): Bool {
  Env.getVarOrDefault("LYRIC_CONFIG_SESSION_REDISSESSION_URL", "").length > 0
}

test "connectRedis() succeeds against a configured Redis server" {
  if not redisConfigured() {
    return
  }
  match Session.connectRedis() {
    case Err(e) -> assertTrue(false, "connectRedis() must succeed: " + e.message)
    case Ok(_) -> ()
  }
}

test "create() returns Ok with a non-empty session ID" {
  if not redisConfigured() {
    return
  }
  match Session.connectRedis() {
    case Err(e) -> assertTrue(false, "connectRedis() must succeed: " + e.message)
    case Ok(store) -> match Session.create(store) { case Err(e) -> assertTrue(false, "create() must succeed: " + e.message); case Ok(sid) -> assertTrue(sid.length > 0, "session ID must be non-empty") }
  }
}

test "create() returns different IDs on successive calls" {
  if not redisConfigured() {
    return
  }
  match Session.connectRedis() {
    case Err(e) -> assertTrue(false, "connectRedis() must succeed: " + e.message)
    case Ok(store) -> match Session.create(store) { case Err(e) -> assertTrue(false, "create() #1 must succeed: " + e.message); case Ok(sid1) -> match Session.create(store) { case Err(e) -> assertTrue(false, "create() #2 must succeed: " + e.message); case Ok(sid2) -> assertTrue(sid1 != sid2, "successive create() calls must produce distinct IDs") } }
  }
}

test "load() for unknown ID returns Ok(None)" {
  if not redisConfigured() {
    return
  }
  match Session.connectRedis() {
    case Err(e) -> assertTrue(false, "connectRedis() must succeed: " + e.message)
    case Ok(store) -> match Session.load(store, "this-id-does-not-exist-in-redis") { case Err(e) -> assertTrue(false, "load() on unknown id must return Ok(None): " + e.message); case Ok(opt) -> match opt { case Some(_) -> assertTrue(false, "load() on unknown id must be None"); case None -> () } }
  }
}

test "set() then get() round-trip" {
  if not redisConfigured() {
    return
  }
  match Session.connectRedis() {
    case Err(e) -> assertTrue(false, "connectRedis() must succeed: " + e.message)
    case Ok(store) -> match Session.create(store) { case Err(e) -> assertTrue(false, "create() must succeed: " + e.message); case Ok(sid) -> { match Session.set(store, sid, "username", "alice") { case Err(e) -> assertTrue(false, "set() must succeed: " + e.message); case Ok(_) -> () }; match Session.get(store, sid, "username") { case Err(e) -> assertTrue(false, "get() must succeed: " + e.message); case Ok(opt) -> match opt { case None -> assertTrue(false, "get() must find value after set()"); case Some(v) -> assertEqual(v, "alice", "round-trip value") } }; val _ = Session.destroy(store, sid) } }
  }
}

test "set() on unknown id returns SESSION_NOT_FOUND (no auto-create)" {
  if not redisConfigured() {
    return
  }
  match Session.connectRedis() {
    case Err(e) -> assertTrue(false, "connectRedis() must succeed: " + e.message)
    case Ok(store) -> match Session.set(store, "no-such-redis-session", "k", "v") { case Ok(_) -> assertTrue(false, "set() on an id the store never issued must fail (session-fixation guard, #316)"); case Err(e) -> assertEqual(e.code, "SESSION_NOT_FOUND", "error code") }
  }
}

test "multiple keys in same session are independent" {
  if not redisConfigured() {
    return
  }
  match Session.connectRedis() {
    case Err(e) -> assertTrue(false, "connectRedis() must succeed: " + e.message)
    case Ok(store) -> match Session.create(store) { case Err(e) -> assertTrue(false, "create() must succeed: " + e.message); case Ok(sid) -> { val _ = Session.set(store, sid, "a", "1"); val _ = Session.set(store, sid, "b", "2"); match Session.get(store, sid, "a") { case Err(e) -> assertTrue(false, "get(a) must succeed: " + e.message); case Ok(optA) -> match optA { case None -> assertTrue(false, "get(a) must find value"); case Some(va) -> assertEqual(va, "1", "key a") } }; match Session.get(store, sid, "b") { case Err(e) -> assertTrue(false, "get(b) must succeed: " + e.message); case Ok(optB) -> match optB { case None -> assertTrue(false, "get(b) must find value"); case Some(vb) -> assertEqual(vb, "2", "key b") } }; val _ = Session.destroy(store, sid) } }
  }
}

test "delete() removes a key but keeps the session" {
  if not redisConfigured() {
    return
  }
  match Session.connectRedis() {
    case Err(e) -> assertTrue(false, "connectRedis() must succeed: " + e.message)
    case Ok(store) -> match Session.create(store) { case Err(e) -> assertTrue(false, "create() must succeed: " + e.message); case Ok(sid) -> { val _ = Session.set(store, sid, "k", "v"); match Session.delete(store, sid, "k") { case Err(e) -> assertTrue(false, "delete() must succeed: " + e.message); case Ok(_) -> () }; match Session.get(store, sid, "k") { case Err(e) -> assertTrue(false, "get() after delete() must succeed: " + e.message); case Ok(opt) -> match opt { case Some(_) -> assertTrue(false, "key must be absent after delete()"); case None -> () } }; match Session.load(store, sid) { case Err(e) -> assertTrue(false, "load() after delete() must succeed: " + e.message); case Ok(opt) -> match opt { case None -> assertTrue(false, "session must still exist after delete() of a key"); case Some(_) -> () } }; val _ = Session.destroy(store, sid) } }
  }
}

test "clear() empties all keys but session still exists" {
  if not redisConfigured() {
    return
  }
  match Session.connectRedis() {
    case Err(e) -> assertTrue(false, "connectRedis() must succeed: " + e.message)
    case Ok(store) -> match Session.create(store) { case Err(e) -> assertTrue(false, "create() must succeed: " + e.message); case Ok(sid) -> { val _ = Session.set(store, sid, "x", "hello"); val _ = Session.set(store, sid, "y", "world"); match Session.clear(store, sid) { case Err(e) -> assertTrue(false, "clear() must succeed: " + e.message); case Ok(_) -> () }; match Session.load(store, sid) { case Err(e) -> assertTrue(false, "load() after clear() must succeed: " + e.message); case Ok(opt) -> match opt { case None -> assertTrue(false, "session must still exist after clear()"); case Some(_) -> () } }; match Session.get(store, sid, "x") { case Err(e) -> assertTrue(false, "get(x) after clear() must succeed: " + e.message); case Ok(opt) -> match opt { case Some(_) -> assertTrue(false, "key x must be absent after clear()"); case None -> () } }; val _ = Session.destroy(store, sid) } }
  }
}

test "touch() refreshes TTL on an existing session" {
  if not redisConfigured() {
    return
  }
  match Session.connectRedis() {
    case Err(e) -> assertTrue(false, "connectRedis() must succeed: " + e.message)
    case Ok(store) -> match Session.create(store) {
      case Err(e) -> assertTrue(false, "create() must succeed: " + e.message)
      case Ok(sid) -> {
        match Session.touch(store, sid) {
          case Err(e) -> assertTrue(false, "touch() on existing session must succeed: " + e.message)
          case Ok(_) -> ()
        }
        // The session must still be loadable after touch() — a broken
        // `EXPIRE` call (e.g. a bad TTL unit conversion) would otherwise
        // either wipe the key immediately or leave it perpetually alive
        // with the wrong TTL; loadability at least confirms the key
        // survived the round-trip through Lettuce.
        match Session.load(store, sid) {
          case Err(e) -> assertTrue(false, "load() after touch() must succeed: " + e.message)
          case Ok(opt) -> match opt { case None -> assertTrue(false, "session must still exist after touch()"); case Some(_) -> () }
        }
        val _ = Session.destroy(store, sid)
      }
    }
  }
}

test "touch() on non-existent session returns Ok (no-op)" {
  if not redisConfigured() {
    return
  }
  match Session.connectRedis() {
    case Err(e) -> assertTrue(false, "connectRedis() must succeed: " + e.message)
    case Ok(store) -> match Session.touch(store, "ghost-redis-session-id") { case Err(e) -> assertTrue(false, "touch() on non-existent session must be Ok: " + e.message); case Ok(_) -> () }
  }
}

test "destroy() makes session disappear from load()" {
  if not redisConfigured() {
    return
  }
  match Session.connectRedis() {
    case Err(e) -> assertTrue(false, "connectRedis() must succeed: " + e.message)
    case Ok(store) -> match Session.create(store) { case Err(e) -> assertTrue(false, "create() must succeed: " + e.message); case Ok(sid) -> { match Session.destroy(store, sid) { case Err(e) -> assertTrue(false, "destroy() must succeed: " + e.message); case Ok(_) -> () }; match Session.load(store, sid) { case Err(e) -> assertTrue(false, "load() after destroy() must be Ok(None): " + e.message); case Ok(opt) -> match opt { case Some(_) -> assertTrue(false, "session must not exist after destroy()"); case None -> () } } } }
  }
}

test "destroy() on non-existent session is idempotent" {
  if not redisConfigured() {
    return
  }
  match Session.connectRedis() {
    case Err(e) -> assertTrue(false, "connectRedis() must succeed: " + e.message)
    case Ok(store) -> match Session.destroy(store, "no-such-redis-session") { case Err(e) -> assertTrue(false, "destroy() on absent session must not fail: " + e.message); case Ok(_) -> () }
  }
}
