//! Testing.Conformance.Cache — conformance suite for `Cache.CacheStore`.
//!
//! `run(factory, advanceSeconds)`:
//!   * `factory` returns a fresh, empty store every call (each case gets its
//!     own).
//!   * `advanceSeconds(n)` moves the time the stores observe forward by `n`
//!     seconds.  An in-process store built with a `Cache.ManualClock` passes
//!     `{ n -> clock.millis = clock.millis + n.toLong() * 1000i64 }`; a store
//!     with no injectable clock (Redis) passes a function that sleeps.
@runtime_checked
@io
package Testing.Conformance.Cache

import Std.Core
import Testing.Conformance
import Cache as CacheLib

/// Run the `CacheStore` contract against stores from `factory`.
@stable(since = "0.1")
pub func run(factory: () -> CacheLib.CacheStore, advanceSeconds: (Int) -> Unit): Checks {
  val c = newChecks("CacheStore")
  runCase(c, "a missing key reads as None", { -> missingKey(c, factory()) })
  runCase(c, "set then get returns the value", { -> setGet(c, factory()) })
  runCase(c, "set overwrites an existing value", { -> overwrite(c, factory()) })
  runCase(c, "keys do not interfere", { -> independentKeys(c, factory()) })
  runCase(c, "values round-trip verbatim", { -> verbatimValues(c, factory()) })
  runCase(c, "delete removes the key and tolerates an absent one", { -> deleteKey(c, factory()) })
  runCase(c, "clear empties the store and the store stays usable", { -> clearStore(c, factory()) })
  runCase(c, "an entry with a TTL expires once the TTL has elapsed", { -> ttlExpires(c, factory(), advanceSeconds) })
  runCase(c, "ttlSeconds = 0 never expires", { -> zeroTtlPersists(c, factory(), advanceSeconds) })
  runCase(
    c,
    "setting again with ttlSeconds = 0 removes an earlier expiry",
    { -> reSetClearsExpiry(c, factory(), advanceSeconds) }
  )
  runCase(
    c,
    "setting again with a TTL replaces the earlier expiry",
    { -> reSetExtendsExpiry(c, factory(), advanceSeconds) }
  )
  runCase(c, "the convenience wrappers agree with the interface", { -> wrappers(c, factory()) })
  return c
}

func missingKey(c: in Checks, store: in CacheLib.CacheStore): Unit {
  expectNone(c, store.get("absent"), "get of a key never set")
}

func setGet(c: in Checks, store: in CacheLib.CacheStore): Unit {
  store.set("k", "v", 0)
  expectSome(c, store.get("k"), "v", "get after set")
}

func overwrite(c: in Checks, store: in CacheLib.CacheStore): Unit {
  store.set("k", "one", 0)
  store.set("k", "two", 0)
  expectSome(c, store.get("k"), "two", "the second set wins")
}

func independentKeys(c: in Checks, store: in CacheLib.CacheStore): Unit {
  store.set("a", "1", 0)
  store.set("b", "2", 0)
  store.delete("a")
  expectNone(c, store.get("a"), "the deleted key is gone")
  expectSome(c, store.get("b"), "2", "the other key is untouched")
}

func verbatimValues(c: in Checks, store: in CacheLib.CacheStore): Unit {
  store.set("empty", "", 0)
  expectSome(c, store.get("empty"), "", "the empty string is a value, not an absent key")
  val padded = "  spaced \t and\nnewline  "
  store.set("padded", padded, 0)
  expectSome(c, store.get("padded"), padded, "whitespace is preserved")
  val unicode = "café 世界"
  store.set("unicode", unicode, 0)
  expectSome(c, store.get("unicode"), unicode, "non-ASCII text is preserved")
  store.set("key with spaces/and:punctuation", "ok", 0)
  expectSome(c, store.get("key with spaces/and:punctuation"), "ok", "punctuation in a key is allowed")
}

func deleteKey(c: in Checks, store: in CacheLib.CacheStore): Unit {
  store.set("k", "v", 0)
  store.delete("k")
  expectNone(c, store.get("k"), "get after delete")
  store.delete("k")
  store.delete("never-set")
  expectNone(c, store.get("never-set"), "deleting an absent key is a no-op")
}

func clearStore(c: in Checks, store: in CacheLib.CacheStore): Unit {
  store.set("a", "1", 0)
  store.set("b", "2", 60)
  store.clear()
  expectNone(c, store.get("a"), "a cleared key")
  expectNone(c, store.get("b"), "a cleared key that had a TTL")
  store.set("a", "again", 0)
  expectSome(c, store.get("a"), "again", "the store accepts entries after clear")
}

func ttlExpires(c: in Checks, store: in CacheLib.CacheStore, advanceSeconds: (Int) -> Unit): Unit {
  store.set("k", "v", 10)
  advanceSeconds(5)
  expectSome(c, store.get("k"), "v", "present before the TTL elapses")
  advanceSeconds(10)
  expectNone(c, store.get("k"), "absent after the TTL elapsed")
}

func zeroTtlPersists(c: in Checks, store: in CacheLib.CacheStore, advanceSeconds: (Int) -> Unit): Unit {
  store.set("k", "v", 0)
  advanceSeconds(3)
  expectSome(c, store.get("k"), "v", "no expiry with ttlSeconds = 0")
}

func reSetClearsExpiry(c: in Checks, store: in CacheLib.CacheStore, advanceSeconds: (Int) -> Unit): Unit {
  store.set("k", "v1", 2)
  store.set("k", "v2", 0)
  advanceSeconds(4)
  expectSome(c, store.get("k"), "v2", "the permanent re-set outlives the earlier TTL")
}

func reSetExtendsExpiry(c: in Checks, store: in CacheLib.CacheStore, advanceSeconds: (Int) -> Unit): Unit {
  store.set("k", "v1", 2)
  store.set("k", "v2", 30)
  advanceSeconds(4)
  expectSome(c, store.get("k"), "v2", "the longer TTL replaces the shorter one")
}

func wrappers(c: in Checks, store: in CacheLib.CacheStore): Unit {
  CacheLib.set(store, "w", "x")
  expectSome(c, CacheLib.get(store, "w"), "x", "Cache.set / Cache.get")
  expectSome(c, store.get("w"), "x", "the interface sees what the wrapper stored")
  CacheLib.setWithTtl(store, "t", "y", 60)
  expectSome(c, CacheLib.get(store, "t"), "y", "Cache.setWithTtl")
  CacheLib.delete(store, "w")
  expectNone(c, store.get("w"), "Cache.delete")
  CacheLib.clear(store)
  expectNone(c, store.get("t"), "Cache.clear")
}
