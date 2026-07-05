//! tests/cache_tests.l — test suite for the Cache package.
//! Tests the in-process store: get/set round-trips, TTL semantics,
//! delete, clear, capacity eviction, overwrites, and multi-key behaviour.
@test_module
package Cache.CacheTests

import Std.Core
import Std.Testing
import Std.Time
import Cache

// ─── get / set round-trip ─────────────────────────────────────────────────────
test "set and get round-trip: stored value is retrieved" {
  val store = Cache.inProcess()
  Cache.set(store, "key1", "value1")
  match Cache.get(store, "key1") {
    case None -> assertTrue(false, "expected Some, got None")
    case Some(v) -> assertEqual(v, "value1", "retrieved value")
  }
}

test "get returns None for a key that was never set" {
  val store = Cache.inProcess()
  match Cache.get(store, "missing") {
    case None -> ()
    case Some(_) -> assertTrue(false, "expected None for missing key")
  }
}

test "set overwrites the previous value when the same key is used twice" {
  val store = Cache.inProcess()
  Cache.set(store, "k", "first")
  Cache.set(store, "k", "second")
  match Cache.get(store, "k") {
    case None -> assertTrue(false, "expected Some after second set")
    case Some(v) -> assertEqual(v, "second", "second set must win")
  }
}

test "multiple distinct keys can coexist in the same store" {
  val store = Cache.inProcess()
  Cache.set(store, "a", "alpha")
  Cache.set(store, "b", "beta")
  Cache.set(store, "c", "gamma")
  match Cache.get(store, "a") {
    case None -> assertTrue(false, "expected 'alpha'")
    case Some(v) -> assertEqual(v, "alpha", "key a")
  }
  match Cache.get(store, "b") {
    case None -> assertTrue(false, "expected 'beta'")
    case Some(v) -> assertEqual(v, "beta", "key b")
  }
  match Cache.get(store, "c") {
    case None -> assertTrue(false, "expected 'gamma'")
    case Some(v) -> assertEqual(v, "gamma", "key c")
  }
}

// ─── delete ───────────────────────────────────────────────────────────────────
test "delete removes the entry so subsequent get returns None" {
  val store = Cache.inProcess()
  Cache.set(store, "temp", "data")
  Cache.delete(store, "temp")
  match Cache.get(store, "temp") {
    case None -> ()
    case Some(_) -> assertTrue(false, "key must be absent after delete")
  }
}

test "delete on an absent key is a no-op (does not error)" {
  val store = Cache.inProcess()
  // Deleting a key that was never set must not panic or error.
  Cache.delete(store, "absent")
  match Cache.get(store, "absent") {
    case None -> ()
    case Some(_) -> assertTrue(false, "absent key must remain None")
  }
}

test "delete removes only the targeted key, leaving others intact" {
  val store = Cache.inProcess()
  Cache.set(store, "x", "keep")
  Cache.set(store, "y", "remove")
  Cache.delete(store, "y")
  match Cache.get(store, "x") {
    case None -> assertTrue(false, "key 'x' must still be present")
    case Some(v) -> assertEqual(v, "keep", "key x after delete of y")
  }
  match Cache.get(store, "y") {
    case None -> ()
    case Some(_) -> assertTrue(false, "key 'y' must be absent after delete")
  }
}

// ─── clear ────────────────────────────────────────────────────────────────────
test "clear removes all entries from the store" {
  val store = Cache.inProcess()
  Cache.set(store, "p", "1")
  Cache.set(store, "q", "2")
  Cache.set(store, "r", "3")
  Cache.clear(store)
  match Cache.get(store, "p") {
    case None -> ()
    case Some(_) -> assertTrue(false, "key 'p' must be absent after clear")
  }
  match Cache.get(store, "q") {
    case None -> ()
    case Some(_) -> assertTrue(false, "key 'q' must be absent after clear")
  }
  match Cache.get(store, "r") {
    case None -> ()
    case Some(_) -> assertTrue(false, "key 'r' must be absent after clear")
  }
}

test "clear on an empty store is a no-op" {
  val store = Cache.inProcess()
  Cache.clear(store)
  match Cache.get(store, "any") {
    case None -> ()
    case Some(_) -> assertTrue(false, "store must remain empty after clear on empty store")
  }
}

test "set after clear inserts a fresh entry" {
  val store = Cache.inProcess()
  Cache.set(store, "k", "before")
  Cache.clear(store)
  Cache.set(store, "k", "after")
  match Cache.get(store, "k") {
    case None -> assertTrue(false, "expected 'after' following clear + re-set")
    case Some(v) -> assertEqual(v, "after", "value after clear and re-set")
  }
}

// ─── setWithTtl (TTL = 0 means no expiry) ────────────────────────────────────
test "setWithTtl with ttl=0 stores the value without expiry" {
  val store = Cache.inProcess()
  Cache.setWithTtl(store, "permanent", "stays", 0)
  match Cache.get(store, "permanent") {
    case None -> assertTrue(false, "expected value stored indefinitely")
    case Some(v) -> assertEqual(v, "stays", "indefinitely stored value")
  }
}

test "setWithTtl with a positive TTL stores the value (immediately readable)" {
  val store = Cache.inProcess()
  // 300 seconds is well in the future; the entry must be visible right away.
  Cache.setWithTtl(store, "short", "live", 300)
  match Cache.get(store, "short") {
    case None -> assertTrue(false, "value with future TTL must be present")
    case Some(v) -> assertEqual(v, "live", "value with TTL")
  }
}

test "setWithTtl with a 1-second TTL expires once the TTL elapses" {
  val store = Cache.inProcess()
  Cache.setWithTtl(store, "expiring", "fleeting", 1)
  match Cache.get(store, "expiring") {
    case None -> assertTrue(false, "value must be present immediately after set")
    case Some(v) -> assertEqual(v, "fleeting", "value before expiry")
  }
  sleepMillis(1100)
  match Cache.get(store, "expiring") {
    case None -> ()
    // expired — correct
    case Some(_) -> assertTrue(false, "value must be absent once its 1-second TTL has elapsed")
  }
}

test "re-setting a TTL'd key with ttl=0 clears the expiry and makes it permanent" {
  val store = Cache.inProcess()
  Cache.setWithTtl(store, "reprieved", "temporary", 1)
  Cache.setWithTtl(store, "reprieved", "permanent", 0)
  sleepMillis(1100)
  match Cache.get(store, "reprieved") {
    case None -> assertTrue(false, "re-setting with ttl=0 must clear the earlier expiry")
    case Some(v) -> assertEqual(v, "permanent", "value after the ttl=0 re-set")
  }
}

// ─── Capacity eviction ────────────────────────────────────────────────────────
test "inProcessWithCapacity(2): inserting a third key evicts the oldest" {
  val store = Cache.inProcessWithCapacity(2)
  Cache.set(store, "first", "1")
  Cache.set(store, "second", "2")
  Cache.set(store, "third", "3")
  // "first" (oldest insertion) must have been evicted.
  match Cache.get(store, "first") {
    case None -> ()
    // evicted — correct
    case Some(_) -> assertTrue(false, "oldest key 'first' must have been evicted")
  }
  // "second" and "third" must still be present.
  match Cache.get(store, "second") {
    case None -> assertTrue(false, "key 'second' must still be present")
    case Some(v) -> assertEqual(v, "2", "second value")
  }
  match Cache.get(store, "third") {
    case None -> assertTrue(false, "key 'third' must still be present")
    case Some(v) -> assertEqual(v, "3", "third value")
  }
}

test "inProcessWithCapacity(1): each new key evicts the only existing entry" {
  val store = Cache.inProcessWithCapacity(1)
  Cache.set(store, "a", "alpha")
  Cache.set(store, "b", "beta")
  // "a" must be gone; "b" must be present.
  match Cache.get(store, "a") {
    case None -> ()
    case Some(_) -> assertTrue(false, "key 'a' must have been evicted by capacity=1")
  }
  match Cache.get(store, "b") {
    case None -> assertTrue(false, "key 'b' must be the surviving entry")
    case Some(v) -> assertEqual(v, "beta", "surviving value")
  }
}

test "inProcessWithCapacity: overwriting an existing key does not inflate count" {
  // With capacity 2, writing the same key twice must not trigger eviction
  // (the store has at most 2 distinct keys at any time).
  val store = Cache.inProcessWithCapacity(2)
  Cache.set(store, "x", "v1")
  Cache.set(store, "y", "v1")
  Cache.set(store, "x", "v2")
  // overwrite — no new key
  // Both x and y must be present.
  match Cache.get(store, "x") {
    case None -> assertTrue(false, "key 'x' must be present after overwrite")
    case Some(v) -> assertEqual(v, "v2", "overwritten value of x")
  }
  match Cache.get(store, "y") {
    case None -> assertTrue(false, "key 'y' must be present")
    case Some(v) -> assertEqual(v, "v1", "value of y")
  }
}
