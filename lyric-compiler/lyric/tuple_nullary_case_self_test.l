//! tuple_nullary_case_self_test.l — runtime regression test for bare generic
//! nullary cases (`None`) inside tuple-valued `match` arms and `if` branches
//! on both self-hosted backends (#7455).
//!
//! Before the fix, the MSIL backend built a bare `None` tuple element as
//! `Option_None<object>` (it had no construction hint: only an annotated tuple
//! context supplies one), while a sibling arm's `Some(b)` built
//! `Option_Some<Box>`.  Destructuring the result then threw
//! `InvalidCastException` at run time, and when the `None` arm came first the
//! join was unverifiable IL (ilverify `StackUnexpected`).  Separately, an
//! enclosing construction hint (an `Option[String]` return type) leaked into
//! the tuple's elements and built `Option_Some<string>` around a `Box`.  The
//! JVM backend was already correct (erased generics); the cases run on both
//! targets so the two stay in agreement.
//!
//! Run by the native `lyric test` on BOTH targets:
//!   lyric test --target dotnet lyric-compiler/lyric/tuple_nullary_case_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/tuple_nullary_case_self_test.l
//! Imports only `Std.*` (no `LYRIC_LOAD_COMPILER=1`).
@test_module
package Lyric.TupleNullaryCaseSelfTest

import Std.Core
import Std.Testing

pub record Box {
  n: Int
}

pub record Holder {
  o: Option[Box]
}

pub union Shape {
  case Both(lo: Box, hi: Box)
  case LowOnly(lo: Box)
  case HighOnly(hi: Box)
}

func optN(o: in Option[Box]): Int {
  match o {
    case Some(x) -> x.n
    case None -> 0
  }
}

func both(): Shape {
  Both(lo = Box(n = 1), hi = Box(n = 2))
}

func lowOnly(): Shape {
  LowOnly(lo = Box(n = 4))
}

func highOnly(): Shape {
  HighOnly(hi = Box(n = 3))
}

// 1. `None` in the first and last tuple positions; a concrete arm comes first.
func endsConcreteFirst(s: in Shape): Int {
  val (lo, hi) = match s {
    case Both(a, b) -> (Some(value = a), Some(value = b))
    case LowOnly(a) -> (Some(value = a), None)
    case HighOnly(b) -> (None, Some(value = b))
  }
  optN(lo) * 100 + optN(hi)
}

// 2. The `None` arms come BEFORE any arm that fixes the element type.
func endsNoneFirst(s: in Shape): Int {
  val (lo, hi) = match s {
    case LowOnly(a) -> (Some(value = a), None)
    case HighOnly(b) -> (None, Some(value = b))
    case Both(a, b) -> (Some(value = a), Some(value = b))
  }
  optN(lo) * 100 + optN(hi)
}

// 3. `None` in the middle of a three-element tuple, from a block arm.
func middleSlot(s: in Shape): Int {
  val (k, m, tag) = match s {
    case Both(a, _) -> (1, Some(value = a), "both")
    case LowOnly(a) -> {
      val z = a.n;
      (z, None, "low")
    }
    case HighOnly(b) -> (b.n, Some(value = b), "high")
  }
  k * 100 + optN(m) * 10 + tag.length
}

// 4. A tuple-valued `if` whose `then` branch carries the bare `None`.
func ifBranches(c: in Bool, b: in Box): Int {
  val (x, y) = if c { (None, 1) } else { (Some(value = b), 2) }
  optN(x) * 10 + y
}

// 5. A nested tuple whose inner tuple carries the bare `None`.
func nestedTuple(s: in Shape): Int {
  val (p, k) = match s {
    case Both(a, _) -> ((Some(value = a), 5), 1)
    case LowOnly(_) -> ((None, 6), 2)
    case HighOnly(b) -> ((Some(value = b), 7), 3)
  }
  val (o, j) = p
  optN(o) * 100 + j * 10 + k
}

// 6. A tuple returned from a function with a declared tuple type.
func returnedTuple(s: in Shape): (Option[Box], Int) {
  match s {
    case Both(a, _) -> (Some(value = a), 1)
    case LowOnly(_) -> (None, 2)
    case HighOnly(b) -> (Some(value = b), 3)
  }
}

// 7. A tuple passed as a call argument.
func takeTuple(t: in (Option[Box], Int)): Int {
  val (o, k) = t
  optN(o) * 10 + k
}

// 8. `None` as a record-constructor field inside a tuple element.
func recordInTuple(s: in Shape): Int {
  val (h, k) = match s {
    case Both(a, _) -> (Holder(o = Some(value = a)), 1)
    case LowOnly(_) -> (Holder(o = None), 2)
    case HighOnly(b) -> (Holder(o = Some(value = b)), 3)
  }
  optN(h.o) * 10 + k
}

// 9. The enclosing `Option[String]` return hint must not reach the elements.
func enclosingHint(s: in Shape): Option[String] {
  val (lo, k) = match s {
    case Both(a, _) -> (Some(value = a), 1)
    case LowOnly(_) -> (None, 2)
    case HighOnly(b) -> (Some(value = b), 3)
  }
  Some(value = toString(optN(lo) * 10 + k))
}

func enclosingHintN(s: in Shape): Int {
  match enclosingHint(s) {
    case Some(v) -> v.length
    case None -> -1
  }
}

// 10. A value-type payload (`Option[Int]`) and an arm that returns early.
func valueTypeSlot(s: in Shape): Int {
  val (o, k) = match s {
    case Both(_, _) -> return -1
    case LowOnly(a) -> (None, a.n)
    case HighOnly(b) -> (Some(value = b.n), 3)
  }
  val ov = match o { case Some(v) -> v; case None -> 0 }
  ov * 10 + k
}

test "None in last position, concrete arm first" {
  assertEqualInt(endsConcreteFirst(both()), 102, "both")
  assertEqualInt(endsConcreteFirst(lowOnly()), 400, "low only")
}

test "None in first position, concrete arm first" {
  assertEqualInt(endsConcreteFirst(highOnly()), 3, "high only")
}

test "None arms before the arm that fixes the type" {
  assertEqualInt(endsNoneFirst(lowOnly()), 400, "low only")
  assertEqualInt(endsNoneFirst(highOnly()), 3, "high only")
  assertEqualInt(endsNoneFirst(both()), 102, "both")
}

test "None in the middle position of a block arm" {
  assertEqualInt(middleSlot(lowOnly()), 403, "low only")
  assertEqualInt(middleSlot(highOnly()), 334, "high only")
}

test "None in a tuple-valued if branch" {
  assertEqualInt(ifBranches(true, Box(n = 5)), 1, "then")
  assertEqualInt(ifBranches(false, Box(n = 5)), 52, "else")
}

test "None in a nested tuple" {
  assertEqualInt(nestedTuple(lowOnly()), 62, "low only")
  assertEqualInt(nestedTuple(highOnly()), 373, "high only")
}

test "None in a returned tuple" {
  assertEqualInt(takeTuple(returnedTuple(lowOnly())), 2, "low only")
  assertEqualInt(takeTuple(returnedTuple(both())), 11, "both")
}

test "None in a tuple call argument" {
  assertEqualInt(takeTuple((None, 9)), 9, "none")
  assertEqualInt(takeTuple((Some(value = Box(n = 2)), 9)), 29, "some")
}

test "None in a record constructor inside a tuple" {
  assertEqualInt(recordInTuple(lowOnly()), 2, "low only")
  assertEqualInt(recordInTuple(highOnly()), 33, "high only")
}

test "enclosing Option return hint does not reach tuple elements" {
  assertEqualInt(enclosingHintN(lowOnly()), 1, "low only")
  assertEqualInt(enclosingHintN(both()), 2, "both")
}

test "value-type Option slot beside an early-return arm" {
  assertEqualInt(valueTypeSlot(lowOnly()), 4, "low only")
  assertEqualInt(valueTypeSlot(highOnly()), 33, "high only")
  assertEqualInt(valueTypeSlot(both()), -1, "both")
}
