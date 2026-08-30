//! stdlib/tests/collections_persistent_tests.l — Tests for
//! Std.Collections.Persistent (#684).
//!
//! Covers: List ops (empty edge cases, cons/head/tail, lookup,
//! insert/delete by index, toList/fromList round trip, non-mutation).
//!
//! Non-mutation here means: deriving a new persistent value from an
//! existing one (e.g. `plistCons(x, a)`) never mutates the original —
//! every test that derives `b` from `a` re-reads `a` afterward and
//! asserts it is unchanged.  This is NOT structural sharing in the
//! traditional persistent-data-structure sense (internal nodes shared
//! across versions for cheap amortized derive operations) — every
//! "modifying" op here does a full O(n) rebuild of a bare `slice[T]`
//! (see the module's own header doc comment).
//!
//! `PersistentMap[K, V]` (#684, #6570) ships in the same module but is
//! tested separately in `collections_persistent_map_tests.l` — dotnet-only
//! for now, see that file's header for why.  Set operations remain a
//! stretch goal, not shipped in this module.
package Std.Collections.Persistent.Tests

import Std.Core
import Std.Collections
import Std.Collections.Persistent
import Std.Testing

func emptyInts(): slice[Int] {
  []
}

// ─── List ops: empty edge cases ──────────────────────────────────────────
func testPlistEmpty(): Unit {
  val e = emptyInts()
  assertTrue(plistIsEmpty(e), "fresh persistent list is empty")
  assertEqualInt(plistLength(e), 0, "empty list length is 0")
  match plistHead(e) {
    case None -> assertTrue(true, "empty list head is None")
    case Some(_) -> assertTrue(false, "empty list head must be None")
  }
  match plistTail(e) {
    case None -> assertTrue(true, "empty list tail is None")
    case Some(_) -> assertTrue(false, "empty list tail must be None")
  }
  match plistLookup(e, 0) {
    case None -> assertTrue(true, "empty list lookup(0) is None")
    case Some(_) -> assertTrue(false, "empty list lookup(0) must be None")
  }
  assertEqualInt(plistToList(e).count, 0, "empty list toList is empty")
}

func testPlistDeleteAndInsertOnEmpty(): Unit {
  val e = emptyInts()
  // Delete on an empty list is a documented no-op.
  assertTrue(plistIsEmpty(plistDelete(e, 0)), "delete on empty list stays empty")
  // Insert on an empty list at any index falls back to cons-at-front.
  val single = plistInsert(e, 5, 42)
  assertEqualInt(plistLength(single), 1, "insert on empty list produces a 1-element list")
  match plistHead(single) {
    case Some(h) -> assertEqualInt(h, 42, "inserted value is the sole element")
    case None -> assertTrue(false, "expected Some(42)")
  }
}

// ─── List ops: cons / head / tail ────────────────────────────────────────
func testPlistConsHeadTail(): Unit {
  val e = emptyInts()
  val a = plistCons(3, e)
  val b = plistCons(2, a)
  val c = plistCons(1, b)
  assertEqualInt(plistLength(c), 3, "three conses yield a 3-element list")
  match plistHead(c) {
    case Some(h) -> assertEqualInt(h, 1, "head is the most recently consed value")
    case None -> assertTrue(false, "expected Some(1)")
  }
  match plistTail(c) {
    case Some(rawT) -> {
      val t: slice[Int] = rawT
      assertEqualInt(plistLength(t), 2, "tail has one fewer element")
    }
    case None -> assertTrue(false, "expected Some(tail)")
  }
}

// ─── List ops: non-mutation (never mutates the input) ────────────────────
func testPlistNonMutation(): Unit {
  val e = emptyInts()
  // Innermost cons evaluates first: plistCons(1, e) = [1], then
  // plistCons(2, [1]) = [2, 1], then plistCons(3, [2, 1]) = [3, 2, 1] —
  // the OUTERMOST cons's value becomes the new head.
  val a = plistCons(3, plistCons(2, plistCons(1, e)))
  // a = [3, 2, 1]
  assertEqualInt(plistLength(a), 3, "baseline a has 3 elements")
  val b = plistCons(0, a)
  // b = [0, 3, 2, 1] — must not mutate a.
  assertEqualInt(plistLength(b), 4, "b has one more element than a")
  assertEqualInt(plistLength(a), 3, "a is unchanged after deriving b (#684 non-mutation)")
  match plistHead(a) {
    case Some(h) -> assertEqualInt(h, 3, "a's head is still 3 after b was derived from it")
    case None -> assertTrue(false, "expected Some(3)")
  }
  // b's tail must equal a exactly (same elements).
  match plistTail(b) {
    case Some(rawT) -> {
      val t: slice[Int] = rawT
      assertEqualInt(plistLength(t), 3, "b's tail has the same length as a")
      match (plistLookup(t, 0), plistLookup(a, 0)) {
        case (Some(t0), Some(a0)) -> assertEqualInt(t0, a0, "b's tail[0] matches a[0]")
        case _ -> assertTrue(false, "expected both lookups to succeed")
      }
    }
    case None -> assertTrue(false, "expected Some(tail)")
  }
}

// ─── List ops: lookup ─────────────────────────────────────────────────────
func testPlistLookup(): Unit {
  val e = emptyInts()
  val lst = plistCons(10, plistCons(20, plistCons(30, e)))
  match plistLookup(lst, 0) {
    case Some(v) -> assertEqualInt(v, 10, "lookup(0)")
    case None -> assertTrue(false, "expected Some(10)")
  }
  match plistLookup(lst, 2) {
    case Some(v) -> assertEqualInt(v, 30, "lookup(2)")
    case None -> assertTrue(false, "expected Some(30)")
  }
  match plistLookup(lst, 3) {
    case None -> assertTrue(true, "lookup past the end is None")
    case Some(_) -> assertTrue(false, "expected None")
  }
  match plistLookup(lst, -1) {
    case None -> assertTrue(true, "negative index is None")
    case Some(_) -> assertTrue(false, "expected None")
  }
}

// ─── List ops: insert / delete by index ──────────────────────────────────
func testPlistInsertMiddleAndEnd(): Unit {
  val e = emptyInts()
  val base = plistCons(10, plistCons(20, plistCons(30, e)))
  // base = [10, 20, 30]
  val withMiddle = plistInsert(base, 1, 99)
  // withMiddle = [10, 99, 20, 30]
  assertEqualInt(plistLength(withMiddle), 4, "insert grows the list by one")
  val asList = plistToList(withMiddle)
  assertEqualInt(asList.count, 4, "toList count matches plistLength")
  assertEqualInt(asList[0], 10, "withMiddle[0]")
  assertEqualInt(asList[1], 99, "withMiddle[1] is the inserted value")
  assertEqualInt(asList[2], 20, "withMiddle[2]")
  assertEqualInt(asList[3], 30, "withMiddle[3]")
  // base must be unchanged (#684 non-mutation).
  assertEqualInt(plistLength(base), 3, "base is unchanged after insert")
  match plistLookup(base, 1) {
    case Some(v) -> assertEqualInt(v, 20, "base[1] is still 20, not 99")
    case None -> assertTrue(false, "expected Some(20)")
  }

  // Insert past the end appends.
  val appended = plistInsert(base, 100, 77)
  val appendedList = plistToList(appended)
  assertEqualInt(appendedList.count, 4, "insert past the end still appends exactly one element")
  assertEqualInt(appendedList[3], 77, "appended value lands at the end")
}

func testPlistDeleteVariants(): Unit {
  val e = emptyInts()
  val base = plistCons(10, plistCons(20, plistCons(30, e)))
  // base = [10, 20, 30]
  val withoutMiddle = plistDelete(base, 1)
  val asList = plistToList(withoutMiddle)
  assertEqualInt(asList.count, 2, "delete shrinks the list by one")
  assertEqualInt(asList[0], 10, "withoutMiddle[0]")
  assertEqualInt(asList[1], 30, "withoutMiddle[1] — the deleted element is gone")
  // base must be unchanged.
  assertEqualInt(plistLength(base), 3, "base is unchanged after delete (#684 non-mutation)")

  // Out-of-range delete is a documented no-op.
  val unchanged = plistDelete(base, 99)
  assertEqualInt(plistLength(unchanged), 3, "out-of-range delete is a no-op")
  val negUnchanged = plistDelete(base, -1)
  assertEqualInt(plistLength(negUnchanged), 3, "negative-index delete is a no-op")
}

// ─── List ops: toList / fromList round trip ──────────────────────────────
func testPlistToFromListRoundTrip(): Unit {
  val src: List[Int] = newList()
  src.add(1)
  src.add(2)
  src.add(3)
  val plist = plistFromList(src)
  assertEqualInt(plistLength(plist), 3, "fromList preserves count")
  val back = plistToList(plist)
  assertEqualInt(back.count, 3, "round-tripped list has the same count")
  assertEqualInt(back[0], 1, "round-trip preserves order [0]")
  assertEqualInt(back[1], 2, "round-trip preserves order [1]")
  assertEqualInt(back[2], 3, "round-trip preserves order [2]")
}

func main(): Unit {
  testPlistEmpty()
  testPlistDeleteAndInsertOnEmpty()
  testPlistConsHeadTail()
  testPlistNonMutation()
  testPlistLookup()
  testPlistInsertMiddleAndEnd()
  testPlistDeleteVariants()
  testPlistToFromListRoundTrip()
  println("collections_persistent_tests: ok")
}
