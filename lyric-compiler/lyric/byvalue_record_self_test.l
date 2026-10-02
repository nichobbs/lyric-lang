//! By-value records (docs/67 §4.2, G1 #7940): the language-level behaviour a
//! record with no `var` field must have whatever its representation.
//!
//! On `--target native` such a record whose fields are all by-value lowers to
//! a plain LLVM struct (no heap allocation, no ARC); the cases here run the
//! whole shared pipeline (`derives Add, Sub`, structural `==`, `.copy`) and so
//! pin the same observable behaviour on every target, with the allocation-free
//! claim itself checked in `llvm_byvalue_record_self_test.l`.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/byvalue_record_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/byvalue_record_self_test.l
//!   lyric test --target native lyric-compiler/lyric/byvalue_record_self_test.l
@test_module
package Lyric.ByValueRecordSelfTest

import Std.Core
import Std.Collections
import Std.Testing

@derive(Add, Sub)
record Vec3 {
  x: Float
  y: Float
  z: Float
}

record Sphere {
  center: Vec3
  radius: Float
}

record Tagged {
  var count: Int
  at: Vec3
}

union Hit {
  case At(point: Vec3)
  case Miss
}

record Box[T] {
  v: T
  n: Int
}

func sum3(v: in Vec3): Float {
  v.x + v.y + v.z
}

func scaled(v: in Vec3, k: in Float): Vec3 {
  Vec3(x = v.x * k, y = v.y * k, z = v.z * k)
}

func hitAt(x: in Float): Hit {
  if x > 0.0 {
    At(point = Vec3(x = x, y = x, z = x))
  } else {
    Miss
  }
}

test "derived Add and Sub accumulate in a loop" {
  var acc = Vec3(x = 0.0, y = 0.0, z = 0.0)
  val step = Vec3(x = 1.0, y = 2.0, z = 3.0)
  var i = 0
  while i < 1000 {
    acc = acc + step
    i = i + 1
  }
  val d = acc - step
  assertTrue(d.x == 999.0f32 and d.y == 1998.0f32 and d.z == 2997.0f32, "1000 steps minus one")
}

test "structural equality over nested records" {
  val a = Sphere(center = Vec3(x = 1.0, y = 2.0, z = 3.0), radius = 4.0)
  val b = Sphere(center = Vec3(x = 1.0, y = 2.0, z = 3.0), radius = 4.0)
  val c = Sphere(center = Vec3(x = 1.0, y = 2.0, z = 3.5), radius = 4.0)
  assertTrue(a == b, "equal fields, equal records")
  assertTrue(a != c, "one differing nested field")
}

test "copy derives a changed value and leaves the original" {
  val a = Vec3(x = 1.0, y = 2.0, z = 3.0)
  val b = a.copy(y = 20.0)
  assertTrue(a.y == 2.0f32 and b.y == 20.0f32 and b.x == 1.0f32, "copy changes only the named field")
}

test "assignment copies the value" {
  var p = Vec3(x = 1.0, y = 1.0, z = 1.0)
  val q = p
  p = scaled(p, 5.0)
  assertTrue(sum3(q) == 3.0f32 and sum3(p) == 15.0f32, "q keeps the old value")
}

test "a by-value record in a mutable record is replaced, not mutated" {
  val t = Tagged(count = 0, at = Vec3(x = 1.0, y = 1.0, z = 1.0))
  val alias = t
  alias.at = scaled(alias.at, 3.0)
  alias.count = alias.count + 1
  assertTrue(t.count == 1 and sum3(t.at) == 9.0f32, "the mutable record is shared (D157)")
}

test "by-value records in a List and a Map" {
  val xs: List[Vec3] = newList()
  var i = 0
  while i < 100 {
    xs.add(Vec3(x = i.toFloat(), y = 1.0, z = 0.0))
    i = i + 1
  }
  var total = 0.0f32
  for v in xs {
    total = total + sum3(v)
  }
  assertTrue(total == 4950.0f32 + 100.0f32, "sum over the list")
  val m: Map[String, Vec3] = newMap()
  m.add("a", Vec3(x = 1.0, y = 2.0, z = 3.0))
  m["a"] = scaled(m["a"], 2.0)
  assertTrue(sum3(m["a"]) == 12.0f32, "map value replaced")
}

test "a by-value record is a union payload" {
  val hit = hitAt(2.0)
  val miss = hitAt(-1.0)
  val r = match hit { case At(p) -> sum3(p); case Miss -> 0.0f32 }
  assertTrue(r == 6.0f32, "payload bound in the match")
  assertTrue(miss == Miss, "the nullary case")
}

test "Option holds a by-value record" {
  val o: Option[Vec3] = Some(Vec3(x = 1.0, y = 2.0, z = 3.0))
  val got = match o { case Some(v) -> sum3(v); case None -> 0.0f32 }
  assertTrue(got == 6.0f32, "Some payload")
}

test "generic records over by-value arguments" {
  val a = Box(v = 7, n = 1)
  val b = Box(v = Vec3(x = 1.0, y = 1.0, z = 1.0), n = 2)
  assertEqualInt(a.v + a.n + b.n, 10, "Box[Int]")
  assertTrue(sum3(b.v) == 3.0f32, "Box[Vec3]")
  assertTrue(a == Box(v = 7, n = 1), "structural equality on a generic record")
}

test "closures capture and return by-value records" {
  val base = Vec3(x = 1.0, y = 2.0, z = 3.0)
  val f = { k: Float -> scaled(base, k) }
  assertTrue(sum3(f(2.0)) == 12.0f32, "captured and returned")
}
