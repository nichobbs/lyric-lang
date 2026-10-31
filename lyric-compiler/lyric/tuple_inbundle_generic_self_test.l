//! tuple_inbundle_generic_self_test.l - runtime regression test for in-bundle
//! generic records and unions destructured from a tuple (#7517).
//!
//! Tuple elements are stored as `object` in the runtime `List<object>`.  The
//! MSIL backend narrowed a destructured element with `castObjectToMsil`, which
//! emitted nothing for an in-bundle closed generic (`MGenericInstByName`), so
//! the binding was typed `Maybe<Box>` while the stack held `object` and
//! ilverify reported a stack-type mismatch at the first use.  The JVM backend
//! erases generics and was already correct; the cases run on both targets so
//! the two stay in agreement.
//!
//! Run by the native `lyric test` on BOTH targets:
//!   lyric test --target dotnet lyric-compiler/lyric/tuple_inbundle_generic_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/tuple_inbundle_generic_self_test.l
//! Imports only `Std.*` (no `LYRIC_LOAD_COMPILER=1`).
@test_module
package Lyric.TupleInbundleGenericSelfTest

import Std.Core
import Std.Testing

pub record Box {
  n: Int
}

pub union Maybe[T] {
  case Just(value: T)
  case Nothing
}

pub record Pair[A, B] {
  first: A
  second: B
}

func maybeN(m: in Maybe[Box]): Int {
  match m {
    case Just(x) -> x.n
    case Nothing -> 0
  }
}

func pairN(p: in Pair[Box, Int]): Int {
  p.first.n * 10 + p.second
}

// 1. The shape from the issue: a generic union built in the tuple.
func unionFromTuple(b: in Box): Int {
  val (m, j) = (Just(value = b), 1)
  maybeN(m) * 10 + j
}

// 2. A generic record built in the tuple.
func recordFromTuple(b: in Box): Int {
  val (p, j) = (Pair(first = b, second = 4), 1)
  pairN(p) * 10 + j
}

// 3. The element is read after being bound, through a match.
func unionMatchedAfter(b: in Box): Int {
  val (m, j) = (Just(value = b), 2)
  val r = match m { case Just(x) -> x.n; case Nothing -> 0 }
  r * 10 + j
}

// 4. A nullary case beside a payload case in the same tuple position.
func nullaryInTuple(c: in Bool, b: in Box): Int {
  val (m, j) = if c { (Nothing, 1) } else { (Just(value = b), 2) }
  maybeN(m) * 10 + j
}

// 5. A tuple of two generic values, destructured together.
func twoGenerics(b: in Box): Int {
  val (m, p) = (Just(value = b), Pair(first = b, second = 2))
  maybeN(m) * 100 + pairN(p)
}

// 6. A tuple returned from a function with a declared tuple type.
func returned(b: in Box): (Maybe[Box], Int) {
  (Just(value = b), 3)
}

func fromReturned(b: in Box): Int {
  val (m, j) = returned(b)
  maybeN(m) * 10 + j
}

test "generic union destructured from a tuple" {
  assertEqualInt(unionFromTuple(Box(n = 7)), 71, "union")
}

test "generic record destructured from a tuple" {
  assertEqualInt(recordFromTuple(Box(n = 7)), 741, "record")
}

test "generic union matched after a tuple destructure" {
  assertEqualInt(unionMatchedAfter(Box(n = 6)), 62, "matched")
}

test "generic nullary case beside a payload case" {
  assertEqualInt(nullaryInTuple(true, Box(n = 5)), 1, "nothing")
  assertEqualInt(nullaryInTuple(false, Box(n = 5)), 52, "just")
}

test "two generic values in one tuple" {
  assertEqualInt(twoGenerics(Box(n = 3)), 332, "both")
}

test "generic union from a returned tuple" {
  assertEqualInt(fromReturned(Box(n = 8)), 83, "returned")
}
