//! map_enhancements_self_test.l — regression tests for Std.Collections map helpers.
//!
//! Covers `mapSize`, `mapIsEmpty` (from main) and the iteration/entry
//! helpers fixed in #3511 and #3512:
//!
//!   - `mapKeys(m)`     → `DictKeyCollection[K,V]` iterated via IEnumerator
//!                         protocol (fix for #3511: extern non-IList iterables)
//!   - `mapValues(m)`   → `DictValueCollection[K,V]` iterated via IEnumerator
//!                         protocol (fix for #3511)
//!   - `mapEntries(m)`  → `List[MapEntry[K,V]]` — construction of generic stdlib
//!                         record (fix for #3512: generic stdlib record construction)
//!   - `mapForEach(m, callback)` — calls `dictGetKeys` internally
//!   - `mapPutAll(dst, src)`     — copies across maps using `dictGetKeys`
//!
//! Run in CI via native `lyric test --target dotnet`.  Imports only `Std.*`.
//! JVM parity for the iteration helpers is tracked in #3676.
@test_module
package Lyric.MapEnhancementsSelfTest

import Std.Core
import Std.Collections
import Std.Testing

// ─────────────────────────────────────────────────────────────────────────────
// mapSize / mapIsEmpty
// ─────────────────────────────────────────────────────────────────────────────

test "mapSize returns zero for empty map" {
  val m: Map[String, Int] = newMap()
  assertEqualInt(mapSize(m), 0, "empty map size is 0")
}

test "mapSize returns correct count after additions" {
  val m: Map[String, Int] = newMap()
  m.add("a", 1)
  m.add("b", 2)
  m.add("c", 3)
  assertEqualInt(mapSize(m), 3, "map with 3 entries size is 3")
}

test "mapSize decreases after removal" {
  val m: Map[String, Int] = newMap()
  m.add("a", 1)
  m.add("b", 2)
  assertEqualInt(mapSize(m), 2, "map size is 2 before removal")
  m.remove("a")
  assertEqualInt(mapSize(m), 1, "map size is 1 after removing one entry")
}

test "mapIsEmpty returns true for empty map" {
  val m: Map[String, Int] = newMap()
  assertTrue(mapIsEmpty(m), "empty map is empty")
}

test "mapIsEmpty returns false for non-empty map" {
  val m: Map[String, Int] = newMap()
  m.add("key", 42)
  assertTrue(not mapIsEmpty(m), "map with entries is not empty")
}

test "mapIsEmpty returns true after removing all entries" {
  val m: Map[String, Int] = newMap()
  m.add("a", 1)
  m.add("b", 2)
  m.remove("a")
  m.remove("b")
  assertTrue(mapIsEmpty(m), "map is empty after removing all entries")
}

// ─────────────────────────────────────────────────────────────────────────────
// Basic map operations (pre-conditions for the iteration tests)
// ─────────────────────────────────────────────────────────────────────────────
test "empty map has zero keys via mapKeys" {
  val m: Map[String, Int] = newMap()
  var count = 0
  for _k in mapKeys(m) {
    count = count + 1
  }
  assertEqualInt(count, 0, "empty map: mapKeys count")
}

test "empty map has zero values via mapValues" {
  val m: Map[String, Int] = newMap()
  var count = 0
  for _v in mapValues(m) {
    count = count + 1
  }
  assertEqualInt(count, 0, "empty map: mapValues count")
}

test "empty map has zero entries" {
  val m: Map[String, Int] = newMap()
  val entries = mapEntries(m)
  assertEqualInt(entries.count, 0, "empty map: mapEntries count")
}

test "mapGet still works after importing Std.Collections" {
  val m: Map[String, Int] = newMap()
  m.add("x", 42)
  match mapGet(m, "x") {
    case Some(v) -> assertEqualInt(v, 42, "mapGet found value")
    case None -> assertTrue(false, "mapGet should find x")
  }
}

test "containsKey still works" {
  val m: Map[String, Int] = newMap()
  m.add("hello", 1)
  assertTrue(m.containsKey("hello"), "containsKey present")
  assertTrue(not m.containsKey("world"), "containsKey absent")
}

// ─────────────────────────────────────────────────────────────────────────────
// mapKeys (#3511) — iterates DictKeyCollection via IEnumerator protocol
// ─────────────────────────────────────────────────────────────────────────────
test "mapKeys iterates all keys of a two-entry map" {
  val m: Map[String, Int] = newMap()
  m.add("a", 1)
  m.add("b", 2)
  var keyCount = 0
  for k in mapKeys(m) {
    assertTrue(m.containsKey(k), "iterated key exists in map")
    keyCount = keyCount + 1
  }
  assertEqualInt(keyCount, 2, "mapKeys yields exactly 2 keys")
}

test "mapKeys count matches map.count" {
  val m: Map[String, Int] = newMap()
  m.add("alpha", 10)
  m.add("beta", 20)
  m.add("gamma", 30)
  var cnt = 0
  for _k in mapKeys(m) {
    cnt = cnt + 1
  }
  assertEqualInt(cnt, m.count, "mapKeys count == map.count")
}

// ─────────────────────────────────────────────────────────────────────────────
// mapValues (#3511) — iterates DictValueCollection via IEnumerator protocol
// ─────────────────────────────────────────────────────────────────────────────
test "mapValues iterates all values of a two-entry map" {
  val m: Map[String, Int] = newMap()
  m.add("a", 1)
  m.add("b", 2)
  val seen: List[Int] = newList()
  for v in mapValues(m) {
    seen.add(v)
  }
  assertEqualInt(seen.count, 2, "mapValues yields 2 values")
  var total = 0
  var i = 0
  while i < seen.count {
    total = total + seen[i]
    i = i + 1
  }
  assertEqualInt(total, 3, "mapValues sum == 3")
}

test "mapValues count matches map.count" {
  val m: Map[String, Int] = newMap()
  m.add("x", 100)
  m.add("y", 200)
  m.add("z", 300)
  var cnt = 0
  for _v in mapValues(m) {
    cnt = cnt + 1
  }
  assertEqualInt(cnt, m.count, "mapValues count == map.count")
}

// ─────────────────────────────────────────────────────────────────────────────
// mapEntries (#3512) — constructs MapEntry[K,V] generic stdlib records
// ─────────────────────────────────────────────────────────────────────────────
test "mapEntries returns correct count" {
  val m: Map[String, Int] = newMap()
  m.add("one", 1)
  m.add("two", 2)
  val entries = mapEntries(m)
  assertEqualInt(entries.count, 2, "mapEntries count == 2")
}

test "mapEntries keys all exist in source map" {
  val m: Map[String, Int] = newMap()
  m.add("foo", 10)
  m.add("bar", 20)
  val entries = mapEntries(m)
  var i = 0
  while i < entries.count {
    assertTrue(m.containsKey(entries[i].key), "entry key in map")
    i = i + 1
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// mapForEach — visits every key/value pair
// ─────────────────────────────────────────────────────────────────────────────
test "mapForEach visits all entries" {
  val m: Map[String, Int] = newMap()
  m.add("p", 7)
  m.add("q", 8)
  val visited: List[String] = newList()
  mapForEach(m, { k: String, v: Int -> visited.add(k) })
  assertEqualInt(visited.count, 2, "mapForEach visited 2 entries")
}

test "mapForEach on empty map visits nothing" {
  val m: Map[String, Int] = newMap()
  var calls = 0
  mapForEach(m, { k: String, v: Int -> calls = calls + 1 })
  assertEqualInt(calls, 0, "mapForEach on empty map: 0 calls")
}

// ─────────────────────────────────────────────────────────────────────────────
// mapPutAll — copies entries from src into dst
// ─────────────────────────────────────────────────────────────────────────────
test "mapPutAll copies all entries from src to empty dst" {
  val src: Map[String, Int] = newMap()
  src.add("x", 1)
  src.add("y", 2)
  val dst: Map[String, Int] = newMap()
  mapPutAll(dst, src)
  assertEqualInt(dst.count, 2, "dst has 2 entries after mapPutAll")
  assertTrue(dst.containsKey("x"), "dst has key x")
  assertTrue(dst.containsKey("y"), "dst has key y")
}

test "mapPutAll overwrites existing keys in dst" {
  val src: Map[String, Int] = newMap()
  src.add("a", 99)
  val dst: Map[String, Int] = newMap()
  dst.add("a", 1)
  dst.add("b", 2)
  mapPutAll(dst, src)
  assertEqualInt(dst.count, 2, "dst count unchanged (same keys)")
  match mapGet(dst, "a") {
    case Some(v) -> assertEqualInt(v, 99, "dst.a overwritten to 99")
    case None -> assertTrue(false, "dst should still have key a")
  }
}
