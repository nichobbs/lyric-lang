//! Component-wise `derives Add, Sub` on homogeneous numeric records (D155).
//!
//! A record whose fields all have one numeric type may derive `Add` and
//! `Sub`; `a + b` and `a - b` then apply field by field to two values of that
//! record type, and `a += b` / `a -= b` assign the result.  The checker
//! records each such operator and `Lyric.ContractElaborator.lowerRecordArith`
//! rewrites it before any backend runs, so these cases pin the same behaviour
//! on every target.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/record_arith_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/record_arith_self_test.l
//!   lyric test --target native lyric-compiler/lyric/record_arith_self_test.l
@test_module
package Lyric.RecordArithSelfTest

import Std.Core
import Std.Testing

@derive(Add, Sub)
record Vec2 {
  x: Float
  y: Float
}

@derive(Add, Sub)
record Vec3i {
  x: Int
  y: Int
  z: Int
}

@derive(Add)
record Bytes2 {
  a: Byte
  b: Byte
}

@derive(Add)
record Tally {
  var n: Long
}

record Counter {
  var calls: Int
}

func next(c: in Counter, v: in Vec3i): Vec3i {
  c.calls = c.calls + 1
  v
}

func midpoint(a: in Vec2, b: in Vec2): Vec2
  ensures: result.x == (a + b).x / 2.0
{
  val s = a + b
  Vec2(x = s.x / 2.0, y = s.y / 2.0)
}

test "Add and Sub apply field by field" {
  val a = Vec2(x = 1.5, y = 2.0)
  val b = Vec2(x = 0.25, y = -1.0)
  val s = a + b
  assertTrue(s.x == 1.75f32 and s.y == 1.0f32, "a + b")
  val d = a - b
  assertTrue(d.x == 1.25f32 and d.y == 3.0f32, "a - b")
  val i = Vec3i(x = 1, y = 2, z = 3) + Vec3i(x = 10, y = 20, z = 30)
  assertEqualInt(i.x + i.y + i.z, 66, "Int fields")
}

test "operators chain left to right" {
  val a = Vec3i(x = 1, y = 1, z = 1)
  val b = Vec3i(x = 2, y = 3, z = 4)
  val c = Vec3i(x = 5, y = 5, z = 5)
  val r = a + b - c
  assertEqualInt(r.x, -2, "x")
  assertEqualInt(r.y, -1, "y")
  assertEqualInt(r.z, 0, "z")
}

test "each operand is evaluated once" {
  val c = Counter(calls = 0)
  val v = Vec3i(x = 1, y = 2, z = 3)
  val r = next(c, v) + next(c, v)
  assertEqualInt(c.calls, 2, "two operands, two calls")
  assertEqualInt(r.z, 6, "result")
}

test "compound assignment" {
  var p = Vec2(x = 1.0, y = 1.0)
  p += Vec2(x = 0.5, y = 2.0)
  p -= Vec2(x = 1.0, y = 1.0)
  assertTrue(p.x == 0.5f32 and p.y == 2.0f32, "p after += and -=")
}

test "Byte fields add as Byte arithmetic" {
  val r = Bytes2(a = 200u8, b = 1u8) + Bytes2(a = 55u8, b = 2u8)
  assertTrue(r.a == 255u8, "200 + 55")
  assertTrue(r.b == 3u8, "1 + 2")
}

test "the result of a mutable record's sum is a new instance" {
  val a = Tally(n = 1i64)
  val b = Tally(n = 2i64)
  val s = a + b
  s.n = 100i64
  assertTrue(a.n == 1i64 and b.n == 2i64, "operands unchanged")
}

test "record arithmetic inside a contract clause" {
  val m = midpoint(Vec2(x = 1.0, y = 2.0), Vec2(x = 3.0, y = 4.0))
  assertTrue(m.x == 2.0f32 and m.y == 3.0f32, "midpoint")
}
