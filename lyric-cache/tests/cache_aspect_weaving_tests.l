//! tests/cache_aspect_weaving_tests.l — runtime weaving tests for the
//! Cache.Aspects templates (FunctionCache, ItemCache).
//!
//! Unlike cache_tests.l (which tests Cache.get/set/delete directly), this
//! module instantiates each aspect against a handler and asserts the *woven*
//! handler actually caches — a weave that silently never hits the cache (or
//! never misses it) is worse than a compile error, so this is the CI guard
//! for it. Mirrors the pattern in
//! lyric-auth/tests/auth_aspect_weaving_tests.l.
@test_module
package Cache.CacheAspectWeavingTests

import Std.Core
import Std.Testing
import Cache.Aspects

// Module-level state must be a `var`-field record bound via `val` (Lyric has
// no module-level `var` primitive) — mirrors Cache.Aspects' own
// `val functionCacheStore: CacheStore = Cache.inProcess()` pattern.
record CallCounter {
  var count: Int
}

// ─── FunctionCache ─────────────────────────────────────────────────────────────
// Guard any handler named `fnCached*` with the FunctionCache template. The
// handler increments a call counter each time it actually runs, so a cache
// hit is observable as "the counter did not increase".
aspect FnCache from Cache.Aspects.FunctionCache {
  matches: name like "fnCached*"
  config {
    ttlSeconds: Int = 300
  }
}

val fnCacheCalls: CallCounter = CallCounter(count = 0)

pub func fnCachedHandler(): Result[String, String] {
  fnCacheCalls.count = fnCacheCalls.count + 1
  return Ok("value-" + fnCacheCalls.count.toString())
}

// FunctionCache is keyed only on call.qualifiedName (no per-call-site
// isolation by design), so its cache slot is shared by every invocation of
// fnCachedHandler across the whole test run — both assertions below must
// live in one test rather than being split across tests that could observe
// each other's cached entry depending on execution order.
test "FunctionCache aspect: first call runs the handler, later calls reuse the cached result" {
  fnCacheCalls.count = 0
  match fnCachedHandler() {
    case Ok(v) -> assertEqual(v, "value-1", "first call returns the handler's fresh value")
    case Err(_) -> assertTrue(false, "handler must return Ok")
  }
  assertEqualInt(fnCacheCalls.count, 1, "handler ran exactly once so far")
  val second = fnCachedHandler()
  val third = fnCachedHandler()
  match second {
    case Ok(v) -> assertEqual(v, "value-1", "second call reuses the first call's cached value")
    case Err(_) -> assertTrue(false, "handler must return Ok")
  }
  match third {
    case Ok(v) -> assertEqual(v, "value-1", "third call still reuses the cached value")
    case Err(_) -> assertTrue(false, "handler must return Ok")
  }
  assertEqualInt(fnCacheCalls.count, 1, "the handler body ran only once across three calls")
}

// The `enabled` master switch must bypass the cache entirely when false.
aspect FnCacheDisabled from Cache.Aspects.FunctionCache {
  matches: name like "fnUncached*"
  config {
    enabled: Bool = false
  }
}

val fnUncachedCalls: CallCounter = CallCounter(count = 0)

pub func fnUncachedHandler(): Result[String, String] {
  fnUncachedCalls.count = fnUncachedCalls.count + 1
  return Ok("value-" + fnUncachedCalls.count.toString())
}

test "FunctionCache aspect: enabled=false runs the handler on every call" {
  fnUncachedCalls.count = 0
  val first = fnUncachedHandler()
  val second = fnUncachedHandler()
  match first {
    case Ok(v) -> assertEqual(v, "value-1", "first call runs the handler")
    case Err(_) -> assertTrue(false, "handler must return Ok")
  }
  match second {
    case Ok(v) -> assertEqual(v, "value-2", "second call re-runs the handler when disabled")
    case Err(_) -> assertTrue(false, "handler must return Ok")
  }
  assertEqualInt(fnUncachedCalls.count, 2, "a disabled cache must not suppress any call")
}

// ─── ItemCache ─────────────────────────────────────────────────────────────────
// Guard any handler named `itemCached*` with the ItemCache template. The
// handler declares the required `cacheKey: String` parameter (checked by the
// weaver's row constraint) and increments a per-process counter so a cache
// hit is observable the same way as FunctionCache above.
aspect ItemCacheGuard from Cache.Aspects.ItemCache {
  matches: name like "itemCached*"
  config {
    ttlSeconds: Int = 300
    keyPrefix: String = "item-test:"
  }
}

val itemCacheCalls: CallCounter = CallCounter(count = 0)

pub func itemCachedHandler(cacheKey: in String): Result[String, String] {
  itemCacheCalls.count = itemCacheCalls.count + 1
  return Ok(cacheKey + "-" + itemCacheCalls.count.toString())
}

test "ItemCache aspect: distinct cacheKeys get independent cache entries" {
  itemCacheCalls.count = 0
  val a1 = itemCachedHandler("alpha")
  val b1 = itemCachedHandler("beta")
  match a1 {
    case Ok(v) -> assertEqual(v, "alpha-1", "first call for 'alpha' runs the handler")
    case Err(_) -> assertTrue(false, "handler must return Ok")
  }
  match b1 {
    case Ok(v) -> assertEqual(v, "beta-2", "first call for a different key also runs the handler")
    case Err(_) -> assertTrue(false, "handler must return Ok")
  }
  assertEqualInt(itemCacheCalls.count, 2, "two distinct keys both missed the cache")
}

test "ItemCache aspect: repeating the same cacheKey reuses the cached value" {
  itemCacheCalls.count = 0
  val first = itemCachedHandler("gamma")
  val second = itemCachedHandler("gamma")
  match first {
    case Ok(v) -> assertEqual(v, "gamma-1", "first call for 'gamma' runs the handler")
    case Err(_) -> assertTrue(false, "handler must return Ok")
  }
  match second {
    case Ok(v) -> assertEqual(v, "gamma-1", "second call for the same key reuses the cached value")
    case Err(_) -> assertTrue(false, "handler must return Ok")
  }
  assertEqualInt(itemCacheCalls.count, 1, "the handler body ran only once for the repeated key")
}

// The `enabled` master switch must bypass the cache entirely, mirroring
// FunctionCache's `fnUncachedHandler` coverage above.
aspect ItemCacheDisabled from Cache.Aspects.ItemCache {
  matches: name like "itemUncached*"
  config {
    enabled: Bool = false
  }
}

val itemUncachedCalls: CallCounter = CallCounter(count = 0)

pub func itemUncachedHandler(cacheKey: in String): Result[String, String] {
  itemUncachedCalls.count = itemUncachedCalls.count + 1
  return Ok(cacheKey + "-" + itemUncachedCalls.count.toString())
}

test "ItemCache aspect: enabled=false runs the handler on every call, even for a repeated cacheKey" {
  itemUncachedCalls.count = 0
  val first = itemUncachedHandler("delta")
  val second = itemUncachedHandler("delta")
  match first {
    case Ok(v) -> assertEqual(v, "delta-1", "first call runs the handler")
    case Err(_) -> assertTrue(false, "handler must return Ok")
  }
  match second {
    case Ok(v) -> assertEqual(v, "delta-2", "second call re-runs the handler when disabled, even with the same cacheKey")
    case Err(_) -> assertTrue(false, "handler must return Ok")
  }
  assertEqualInt(itemUncachedCalls.count, 2, "a disabled cache must not suppress any call")
}
