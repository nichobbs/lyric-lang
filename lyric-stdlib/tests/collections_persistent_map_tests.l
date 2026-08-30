//! stdlib/tests/collections_persistent_map_tests.l — Tests for
//! `Std.Collections.Persistent`'s `PersistentMap[K, V]` operations
//! (#684, #6570).
//!
//! Covers: empty edge cases, lookup/containsKey, insert including
//! overwrite semantics, delete including the no-op path, toList/fromList
//! round trip, and non-mutation.
//!
//! Non-mutation here means the same thing it means in
//! `collections_persistent_tests.l`: deriving a new map from an existing
//! one (e.g. `pmapInsert(m, k, v, eq)`) never mutates the original —
//! every test that derives `b` from `a` re-reads `a` afterward and
//! asserts it is unchanged.
//!
//! **dotnet-only, not `--target jvm`** (unlike the sibling List-ops test
//! file, which is CI-verified on both targets): reading a field off a
//! generic-record element obtained by indexing a `List[MapEntry[K, V]]`
//! returned from a generic function call — `pmapToList(m)[i].key` — hits
//! a genuine, separate JVM self-hosted-backend generics-erasure gap
//! (`error[J007]: member 'key' cannot be resolved on an erased
//! (statically Object) receiver`), reproducible even with an explicit
//! local-variable type annotation on the indexed element. This is
//! unrelated to #6568/#6569 (both scoped to the self-hosted MSIL
//! backend, and fixed) — it is a new, previously-undiscovered gap in the
//! JVM backend's generic-function-return-type tracking, tracked
//! separately in #6708; `PersistentMap` stays dotnet-only until that
//! lands, per the "gap is a tracked, dated issue — not an undocumented
//! silent skip" standard.
package Std.Collections.Persistent.MapTests

import Std.Core
import Std.Collections
import Std.Collections.Persistent
import Std.Testing

func intEq(a: in Int, b: in Int): Bool {
  a == b
}

func emptyEntries(): slice[MapEntry[Int, String]] {
  []
}

// ─── empty edge cases ─────────────────────────────────────────────────────
func testPmapEmpty(): Unit {
  val e = emptyEntries()
  assertTrue(pmapIsEmpty(e), "fresh persistent map is empty")
  assertEqualInt(pmapSize(e), 0, "empty map size is 0")
  match pmapLookup(e, 1, intEq) {
    case None -> assertTrue(true, "empty map lookup is None")
    case Some(_) -> assertTrue(false, "empty map lookup must be None")
  }
  assertFalse(pmapContainsKey(e, 1, intEq), "empty map containsKey is false")
  assertEqualInt(pmapToList(e).count, 0, "empty map toList is empty")
}

func testPmapDeleteOnEmpty(): Unit {
  val e = emptyEntries()
  // Delete on an empty map is a documented no-op.
  assertTrue(pmapIsEmpty(pmapDelete(e, 1, intEq)), "delete on empty map stays empty")
}

// ─── insert / lookup / containsKey ────────────────────────────────────────
func testPmapInsertAndLookup(): Unit {
  val e = emptyEntries()
  val m1 = pmapInsert(e, 1, "one", intEq)
  val m2 = pmapInsert(m1, 2, "two", intEq)
  assertEqualInt(pmapSize(m2), 2, "two distinct-key inserts yield a 2-entry map")
  match pmapLookup(m2, 1, intEq) {
    case Some(v) -> assertEqual(v, "one", "lookup(1)")
    case None -> assertTrue(false, "expected Some(\"one\")")
  }
  match pmapLookup(m2, 2, intEq) {
    case Some(v) -> assertEqual(v, "two", "lookup(2)")
    case None -> assertTrue(false, "expected Some(\"two\")")
  }
  match pmapLookup(m2, 3, intEq) {
    case None -> assertTrue(true, "lookup of a missing key is None")
    case Some(_) -> assertTrue(false, "expected None")
  }
  assertTrue(pmapContainsKey(m2, 1, intEq), "containsKey(1) is true")
  assertFalse(pmapContainsKey(m2, 3, intEq), "containsKey(3) is false")
}

// ─── insert overwrite semantics ───────────────────────────────────────────
func testPmapInsertOverwrite(): Unit {
  val e = emptyEntries()
  val m1 = pmapInsert(e, 1, "one", intEq)
  val m2 = pmapInsert(m1, 2, "two", intEq)
  // Re-inserting an existing key replaces the value, not the entry count.
  val m3 = pmapInsert(m2, 1, "ONE", intEq)
  assertEqualInt(pmapSize(m3), 2, "overwriting an existing key does not grow the map")
  match pmapLookup(m3, 1, intEq) {
    case Some(v) -> assertEqual(v, "ONE", "overwritten value replaces the old one")
    case None -> assertTrue(false, "expected Some(\"ONE\")")
  }
  match pmapLookup(m3, 2, intEq) {
    case Some(v) -> assertEqual(v, "two", "untouched key keeps its value")
    case None -> assertTrue(false, "expected Some(\"two\")")
  }
  // The overwritten entry keeps its original position.
  val asList = pmapToList(m3)
  assertEqualInt(asList[0].key, 1, "overwritten entry stays at its original position")
  assertEqualInt(asList[1].key, 2, "untouched entry stays at its position")
}

// ─── non-mutation (never mutates the input) ───────────────────────────────
func testPmapNonMutation(): Unit {
  val e = emptyEntries()
  val a = pmapInsert(pmapInsert(e, 1, "one", intEq), 2, "two", intEq)
  assertEqualInt(pmapSize(a), 2, "baseline a has 2 entries")
  val b = pmapInsert(a, 3, "three", intEq)
  assertEqualInt(pmapSize(b), 3, "b has one more entry than a")
  assertEqualInt(pmapSize(a), 2, "a is unchanged after deriving b (#684 non-mutation)")
  match pmapLookup(a, 3, intEq) {
    case None -> assertTrue(true, "a still has no key 3 after b was derived from it")
    case Some(_) -> assertTrue(false, "a must not see b's insert")
  }
  // Overwriting a key in b must not affect a's value for that key.
  val c = pmapInsert(b, 1, "ONE", intEq)
  match pmapLookup(a, 1, intEq) {
    case Some(v) -> assertEqual(v, "one", "a's value for key 1 is unchanged after c overwrote it")
    case None -> assertTrue(false, "expected Some(\"one\")")
  }
  match pmapLookup(c, 1, intEq) {
    case Some(v) -> assertEqual(v, "ONE", "c has the overwritten value")
    case None -> assertTrue(false, "expected Some(\"ONE\")")
  }
}

// ─── delete ────────────────────────────────────────────────────────────────
func testPmapDelete(): Unit {
  val e = emptyEntries()
  val base = pmapInsert(pmapInsert(pmapInsert(e, 1, "one", intEq), 2, "two", intEq), 3, "three", intEq)
  val withoutTwo = pmapDelete(base, 2, intEq)
  assertEqualInt(pmapSize(withoutTwo), 2, "delete shrinks the map by one")
  assertFalse(pmapContainsKey(withoutTwo, 2, intEq), "deleted key is gone")
  assertTrue(pmapContainsKey(withoutTwo, 1, intEq), "untouched key 1 remains")
  assertTrue(pmapContainsKey(withoutTwo, 3, intEq), "untouched key 3 remains")
  // base must be unchanged (#684 non-mutation).
  assertEqualInt(pmapSize(base), 3, "base is unchanged after delete")
  assertTrue(pmapContainsKey(base, 2, intEq), "base still has key 2")

  // Deleting a missing key is a documented no-op.
  val unchanged = pmapDelete(base, 99, intEq)
  assertEqualInt(pmapSize(unchanged), 3, "deleting a missing key is a no-op")
}

// ─── toList / fromList round trip ─────────────────────────────────────────
func testPmapToFromListRoundTrip(): Unit {
  val src: List[MapEntry[Int, String]] = newList()
  src.add(MapEntry(key = 1, value = "one"))
  src.add(MapEntry(key = 2, value = "two"))
  val pmap = pmapFromList(src)
  assertEqualInt(pmapSize(pmap), 2, "fromList preserves count")
  val back = pmapToList(pmap)
  assertEqualInt(back.count, 2, "round-tripped map has the same count")
  assertEqualInt(back[0].key, 1, "round-trip preserves order [0].key")
  assertEqual(back[0].value, "one", "round-trip preserves order [0].value")
  assertEqualInt(back[1].key, 2, "round-trip preserves order [1].key")
  assertEqual(back[1].value, "two", "round-trip preserves order [1].value")
}

func main(): Unit {
  testPmapEmpty()
  testPmapDeleteOnEmpty()
  testPmapInsertAndLookup()
  testPmapInsertOverwrite()
  testPmapNonMutation()
  testPmapDelete()
  testPmapToFromListRoundTrip()
  println("collections_persistent_map_tests: ok")
}
