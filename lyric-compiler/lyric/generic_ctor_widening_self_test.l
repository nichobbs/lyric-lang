//! generic_ctor_widening_self_test.l — cross-target runtime regression test
//! for implicit lossless widening through generic constructor arguments and
//! tuple elements (#7813).
//!
//! A scalar given where the expected type fixes a wider scalar widens like
//! any initialiser (docs/01 §4.1): `Some(i)` where an `Option[Long]` is
//! expected, `Ok(b)` where a `Result[Int, String]` is, `(i, 1)` where a
//! `(Long, Int)` is, and every nesting of them.  These were rejected with
//! T0060.  The type checker now checks each argument against its field at the
//! expected instantiation and records the widening, which `Lyric.Mono` spells
//! out as `.toLong()` / `.toInt()` / `.toDouble()` before construction:
//! a generic slot is boxed (JVM, native) or reified at the argument's own type
//! (dotnet), so no backend could widen the scalar there itself.
//!
//! Covered: annotated bindings, `return`, a function body's value, call
//! arguments, record fields, list literals, bare, qualified and nested union
//! cases, generic records and unions, tuples, and tuples inside them, along
//! `Byte < Int < Long` and `Float < Double`.  The `Byte < UInt < ULong` chain
//! (which also must zero-extend) is `generic_ctor_unsigned_widening_self_test.l`
//! — native has no unsigned integer types yet.
//!
//! Run via `lyric test`:
//!
//!   lyric test --target dotnet lyric-compiler/lyric/generic_ctor_widening_self_test.l
//!   lyric test --target jvm lyric-compiler/lyric/generic_ctor_widening_self_test.l
//!   lyric test --target native lyric-compiler/lyric/generic_ctor_widening_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.GenericCtorWideningSelfTest

import Std.Core
import Std.Collections
import Std.Testing

record Box[T] {
  value: T
}

record Pair[A, B] {
  first: A
  second: B
}

union Shape[T] {
  case Circle(radius: T)
  case Rect(width: T, height: T)
}

record Settings {
  limit: Option[Long]
  span: (Long, Int)
}

// 3000000000 does not fit an `Int`: a sum that keeps it proves the value
// arrived as a `Long`.
func big(): Long {
  3000000000i64
}

func optLong(o: in Option[Long]): Long {
  match o {
    case Some(v) -> v + big()
    case None -> -1i64
  }
}

func resLong(r: in Result[Long, String]): Long {
  match r {
    case Ok(v) -> v + big()
    case Err(_) -> -1i64
  }
}

func tupleSum(t: in (Long, Int)): Long {
  val (a, b) = t
  a + big() + b.toLong()
}

func shapeSum(s: in Shape[Long]): Long {
  match s {
    case Circle(r) -> r + big()
    case Rect(w, h) -> w + h + big()
  }
}

func returnSome(i: in Int): Option[Long] {
  return Some(i)
}

func tailOk(i: in Int): Result[Long, String] {
  Ok(i)
}

func exprTuple(i: in Int): (Long, Int) = (i, 7)

func takesOpt(o: in Option[Long]): Long {
  optLong(o)
}

func takesTuple(t: in (Long, Int)): Long {
  tupleSum(t)
}

func takesBox(b: in Box[Long]): Long {
  b.value + big()
}

test "Some widens an Int to Long in an annotated binding" {
  val i: Int = -5
  val o: Option[Long] = Some(i)
  assertEqualLong(optLong(o), 2999999995i64, "Some(i) as Option[Long]")
}

test "Some widens a Byte to Int and to Long" {
  val b: Byte = 200.toByte()
  val oi: Option[Int] = Some(b)
  val total = match oi { case Some(v) -> v + 1000; case None -> -1 }
  assertEqualInt(total, 1200, "Some(b) as Option[Int] zero-extends the Byte")
  val ol: Option[Long] = Some(b)
  assertEqualLong(optLong(ol), 3000000200i64, "Some(b) as Option[Long]")
}

test "Ok and Err widen to their own type argument" {
  val i: Int = 41
  val r: Result[Long, String] = Ok(i)
  assertEqualLong(resLong(r), 3000000041i64, "Ok(i) as Result[Long, String]")
  val e: Result[String, Long] = Err(i)
  val got = match e { case Ok(_) -> -1i64; case Err(v) -> v + big() }
  assertEqualLong(got, 3000000041i64, "Err(i) as Result[String, Long]")
}

test "named case arguments widen" {
  val i: Int = 2
  val r: Result[Long, String] = Ok(value = i)
  assertEqualLong(resLong(r), 3000000002i64, "Ok(value = i)")
}

test "Float widens to Double" {
  val f: Float = 0.1
  val o: Option[Double] = Some(f)
  val d = match o { case Some(v) -> v; case None -> -1.0 }
  assertTrue(d == f.toDouble(), "Some(f) as Option[Double] holds the Float's exact value")
  val t: (Double, Int) = (f, 1)
  val (td, _) = t
  assertTrue(td == f.toDouble(), "(f, 1) as (Double, Int)")
}

test "tuple elements widen" {
  val i: Int = 9
  val t: (Long, Int) = (i, 1)
  assertEqualLong(tupleSum(t), 3000000010i64, "(i, 1) as (Long, Int)")
  val b: Byte = 255.toByte()
  val t2: (Int, Long) = (b, i)
  val (x, y) = t2
  assertEqualInt(x, 255, "a Byte element widens to Int")
  assertEqualLong(y + big(), 3000000009i64, "an Int element widens to Long")
}

test "nested constructions widen at every level" {
  val i: Int = 4
  val ot: Option[(Long, Int)] = Some((i, 1))
  val s1 = match ot { case Some(t) -> tupleSum(t); case None -> -1i64 }
  assertEqualLong(s1, 3000000005i64, "Some((i, 1)) as Option[(Long, Int)]")
  val oo: Option[Option[Long]] = Some(Some(i))
  val s2 = match oo { case Some(inner) -> optLong(inner); case None -> -1i64 }
  assertEqualLong(s2, 3000000004i64, "Some(Some(i)) as Option[Option[Long]]")
  val ro: Result[Option[Long], String] = Ok(Some(i))
  val s3 = match ro { case Ok(inner) -> optLong(inner); case Err(_) -> -1i64 }
  assertEqualLong(s3, 3000000004i64, "Ok(Some(i)) as Result[Option[Long], String]")
  val to: (Option[Long], Int) = (Some(i), 2)
  val (first, _) = to
  assertEqualLong(optLong(first), 3000000004i64, "(Some(i), 2) as (Option[Long], Int)")
}

test "list literal elements widen inside tuples and cases" {
  val i: Int = 1
  val j: Int = 2
  val xs: List[(Long, Int)] = [(i, 10), (j, 20)]
  var total = 0i64
  for t in xs {
    total = total + tupleSum(t)
  }
  assertEqualLong(total, 6000000033i64, "[(i, 10), (j, 20)] as List[(Long, Int)]")
  val os: List[Option[Long]] = [Some(i), None, Some(j)]
  var sum = 0i64
  for o in os {
    sum = sum + optLong(o)
  }
  assertEqualLong(sum, 6000000002i64, "[Some(i), None, Some(j)] as List[Option[Long]]")
}

test "generic records widen positional and named arguments" {
  val i: Int = 6
  val b: Box[Long] = Box(i)
  assertEqualLong(takesBox(b), 3000000006i64, "Box(i) as Box[Long]")
  val p: Pair[Long, Double] = Pair(first = i, second = 0.5f32)
  assertEqualLong(p.first + big(), 3000000006i64, "Pair(first = i, ...) as Pair[Long, Double]")
  assertTrue(p.second == 0.5, "a Float field argument widens to Double")
  val bt: Box[(Long, Int)] = Box(value = (i, 3))
  assertEqualLong(tupleSum(bt.value), 3000000009i64, "Box(value = (i, 3)) as Box[(Long, Int)]")
}

test "generic union cases widen" {
  val i: Int = 3
  val c: Shape[Long] = Circle(i)
  assertEqualLong(shapeSum(c), 3000000003i64, "Circle(i) as Shape[Long]")
  val r: Shape[Long] = Rect(width = i, height = i)
  assertEqualLong(shapeSum(r), 3000000006i64, "Rect(width = i, height = i) as Shape[Long]")
}

test "qualified case constructors widen" {
  val i: Int = 8
  val o: Option[Long] = Option.Some(i)
  assertEqualLong(optLong(o), 3000000008i64, "Option.Some(i) as Option[Long]")
  val r: Result[Long, String] = Result.Ok(i)
  assertEqualLong(resLong(r), 3000000008i64, "Result.Ok(i) as Result[Long, String]")
}

test "return, body value and expression body widen" {
  assertEqualLong(optLong(returnSome(10)), 3000000010i64, "return Some(i)")
  assertEqualLong(resLong(tailOk(11)), 3000000011i64, "a body's Ok(i)")
  assertEqualLong(tupleSum(exprTuple(12)), 3000000019i64, "an expression body's (i, 7)")
}

test "call arguments widen" {
  val i: Int = 13
  assertEqualLong(takesOpt(Some(i)), 3000000013i64, "Some(i) given an Option[Long] parameter")
  assertEqualLong(takesTuple((i, 1)), 3000000014i64, "(i, 1) given a (Long, Int) parameter")
  assertEqualLong(takesBox(Box(i)), 3000000013i64, "Box(i) given a Box[Long] parameter")
}

test "record fields widen" {
  val i: Int = 14
  val s = Settings(limit = Some(i), span = (i, 1))
  assertEqualLong(optLong(s.limit), 3000000014i64, "Some(i) given an Option[Long] field")
  assertEqualLong(tupleSum(s.span), 3000000015i64, "(i, 1) given a (Long, Int) field")
}

test "assignment widens" {
  val i: Int = 15
  var o: Option[Long] = None
  o = Some(i)
  assertEqualLong(optLong(o), 3000000015i64, "o = Some(i) for an Option[Long] var")
  var t: (Long, Int) = (0i64, 0)
  t = (i, 2)
  assertEqualLong(tupleSum(t), 3000000017i64, "t = (i, 2) for a (Long, Int) var")
}

test "an integer literal argument takes the slot's type" {
  val r: Result[Long, String] = Ok(42)
  assertEqualLong(resLong(r), 3000000042i64, "Ok(42) as Result[Long, String]")
  val t: (Long, Double) = (7, 0.5)
  val (a, d) = t
  assertEqualLong(a + big(), 3000000007i64, "(7, 0.5) as (Long, Double)")
  assertTrue(d == 0.5, "the Double element")
}
