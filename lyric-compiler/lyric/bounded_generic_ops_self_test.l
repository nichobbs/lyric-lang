//! Operators on a type parameter its `where` clause bounds (#7996, #8017).
//!
//! `where T: Add` makes `a + b` valid in the generic body, `where T: Compare`
//! the relational operators.  The checker types the operator on the bounded
//! parameter; each specialisation is then checked again as the ordinary
//! function it is, so an operator on a distinct type or a homogeneous numeric
//! record is lowered for that type exactly as it would be written by hand.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/bounded_generic_ops_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/bounded_generic_ops_self_test.l
@test_module
package Lyric.BoundedGenericOpsSelfTest

import Std.Core
import Std.Collections
import Std.Testing

type Score = Int derives Add, Sub, Mul, Compare

type Cents = Long range 0 ..= 100000 derives Add, Sub, Compare

@derive(Add, Sub)
record Vec3 {
  x: Float
  y: Float
  z: Float
}

@derive(Add, Sub)
record Pair2 {
  a: Int
  b: Int
}

func sum2[T](a: in T, b: in T): T
  where T: Add
{
  a + b
}

func diff2[T](a: in T, b: in T): T
  where T: Sub
{
  a - b
}

func scale2[T](a: in T, b: in T): T
  where T: Mul
{
  a * b
}

func lerp[T](a: in T, b: in T): T
  where T: Add + Sub
{
  a + (b - a)
}

func maxOf[T](a: in T, b: in T): T
  where T: Compare
{
  if a > b {
    a
  } else {
    b
  }
}

func inRange[T](x: in T, lo: in T, hi: in T): Bool
  where T: Compare
{
  lo <= x and x <= hi
}

func strictlyBefore[T](a: in T, b: in T): Bool
  where T: Compare
{
  a < b
}

func halve[T](a: in T, two: in T): T
  where T: Div
{
  a / two
}

func remainder[T](a: in T, m: in T): T
  where T: Mod
{
  a % m
}

func sum[T](xs: in slice[T]): T
  where T: Add + Default
{
  var total = T.default()
  for x in xs {
    total = total + x
  }
  total
}

func accumulate[T](xs: in slice[T], start: in T): T
  where T: Add
{
  var total = start
  for x in xs {
    total += x
  }
  total
}

test "Add on primitives" {
  assertEqual(toString(sum2(2, 3)), "5", "Int")
  assertEqual(toString(sum2(2i64, 40i64)), "42", "Long")
  assertEqual(toString(sum2(1.5, 2.0)), "3.5", "Double")
  assertEqual(toString(sum2(4000000000u32, 1u32)), "4000000001", "UInt does not wrap through Int")
  assertEqual(sum2("ab", "cd"), "abcd", "String concatenates")
}

test "Sub, Mul, Div and Mod on primitives" {
  assertEqual(toString(diff2(9, 4)), "5", "Sub")
  assertEqual(toString(scale2(6, 7)), "42", "Mul")
  assertEqual(toString(halve(9, 2)), "4", "Int Div")
  assertEqual(toString(halve(9.0, 2.0)), "4.5", "Double Div")
  assertEqual(toString(remainder(9, 4)), "1", "Mod")
  assertEqual(toString(halve(4000000000u32, 2u32)), "2000000000", "UInt Div is unsigned")
}

test "Compare on primitives" {
  assertEqual(toString(maxOf(3, 8)), "8", "Int")
  assertEqual(toString(maxOf(3.5, 2.5)), "3.5", "Double")
  assertEqual(maxOf("apple", "pear"), "pear", "String")
  assertTrue(strictlyBefore(1, 2), "<")
  assertTrue(not strictlyBefore(2, 2), "< on equal")
  assertTrue(inRange(5, 1, 9), "<= and <=")
  assertTrue(not inRange(10, 1, 9), "above the range")
  assertEqual(toString(maxOf(4000000000u32, 5u32)), "4000000000", "UInt compares unsigned")
  assertTrue(not strictlyBefore(4000000000u32, 5u32), "UInt < is unsigned")
}

test "operators on a distinct type go through the underlying value" {
  assertEqual(toString(sum2(Score.from(20), Score.from(22))), "42", "Add")
  assertEqual(toString(diff2(Score.from(50), Score.from(8))), "42", "Sub")
  assertEqual(toString(scale2(Score.from(6), Score.from(7))), "42", "Mul")
  assertEqual(toString(lerp(Score.from(10), Score.from(52))), "52", "Add and Sub together")
  assertEqual(toString(maxOf(Score.from(3), Score.from(9))), "9", "Compare")
  assertTrue(strictlyBefore(Score.from(1), Score.from(2)), "<")
  assertTrue(inRange(Score.from(5), Score.from(1), Score.from(9)), "<=")
}

test "a range subtype is re-checked in the generic body" {
  assertEqual(toString(sum2(Cents.from(250i64), Cents.from(750i64))), "1000", "Add within the range")
  assertEqual(toString(diff2(Cents.from(900i64), Cents.from(150i64))), "750", "Sub within the range")
  assertEqual(toString(maxOf(Cents.from(5i64), Cents.from(3i64))), "5", "Compare")
}

test "component-wise operators on a record" {
  val s = sum2(Vec3(x = 1.0, y = 2.0, z = 3.0), Vec3(x = 0.5, y = 0.5, z = 0.5))
  assertEqual(toString(s.x), "1.5", "x")
  assertEqual(toString(s.y), "2.5", "y")
  assertEqual(toString(s.z), "3.5", "z")
  val d = diff2(Pair2(a = 10, b = 20), Pair2(a = 1, b = 2))
  assertEqual(toString(d.a), "9", "a")
  assertEqual(toString(d.b), "18", "b")
  val l = lerp(Pair2(a = 1, b = 2), Pair2(a = 11, b = 12))
  assertEqual(toString(l.a), "11", "lerp a")
  assertEqual(toString(l.b), "12", "lerp b")
}

ref record Trace {
  var order: Int
}

func traced(t: in Trace, step: in Int, v: in Pair2): Pair2 {
  t.order = t.order * 10 + step
  v
}

test "operands are evaluated once, left to right, for a record" {
  val t = Trace(order = 0)
  val s = sum2(traced(t, 1, Pair2(a = 1, b = 2)), traced(t, 2, Pair2(a = 3, b = 4)))
  assertEqual(toString(t.order), "12", "left then right, once each")
  assertEqual(toString(s.a), "4", "a")
  assertEqual(toString(s.b), "6", "b")
}

test "the docs sum example, specialised at several types" {
  assertEqual(toString(sum([1, 2, 3])), "6", "Int")
  assertEqual(toString(sum([10000000000i64, 5i64])), "10000000005", "Long")
  assertEqual(toString(sum([0.5, 0.25])), "0.75", "Double")
  assertEqual(toString(sum([3000000000u32, 1000000000u32])), "4000000000", "UInt")
}

test "compound assignment on a bounded type parameter" {
  assertEqual(toString(accumulate([4, 5], 1)), "10", "Int")
  assertEqual(toString(accumulate([Score.from(4), Score.from(5)], Score.from(1))), "10", "distinct")
  val acc = accumulate([Pair2(a = 1, b = 1), Pair2(a = 2, b = 3)], Pair2(a = 0, b = 0))
  assertEqual(toString(acc.a), "3", "record a")
  assertEqual(toString(acc.b), "4", "record b")
}
