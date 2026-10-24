//! generic_member_calls_self_test.l -- runtime regression tests for generic
//! function calls made from a record's in-body methods (#8271, #8370).
//!
//! `Lyric.Mono` used to leave a record method's body untouched, so any
//! generic call in it dangled (T0123 on dotnet, a missing class on the JVM).
//! A call at the record's own type parameter cannot be a top-level
//! specialisation, so it is specialised into a method of the record.
//! Runs on dotnet and the JVM.
@test_module
package Lyric.GenericMemberCallsSelfTest

import Std.Core
import Std.Collections
import Std.Testing

func ident[A](x: in A): A = x

func pair[A](x: in A): List[A] {
  val l: List[A] = newList()
  l.add(ident(x))
  l.add(x)
  l
}

record Plain {
  n: Int
  func viaIdent(self: in Plain): Int = ident(self.n)
  func viaPair(self: in Plain): Int = pair(self.n).count
}

record Box[T] {
  v: T
  func echo(self: in Box[T]): T = ident(self.v)
  func twice(self: in Box[T]): List[T] = pair(self.v)
}

record Other[T] {
  v: T
  func echo(self: in Other[T]): T = ident(self.v)
}

func firstOf[T](xs: in array[2, T], k: in Int): T {
  xs[k]
}

func t3[T](x: in T, y: in T): T {
  firstOf[T]([x, y], 0)
}

record Point {
  x: Int
  y: Int
}

test "a non-generic record method calls a generic function" {
  val p: Plain = Plain(n = 41)
  assertEqualInt(p.viaIdent(), 41, "ident at Int")
  assertEqualInt(p.viaPair(), 2, "pair at Int")
}

test "a generic record method calls a generic function at the record's parameter" {
  val bi: Box[Int] = Box(v = 7)
  val bs: Box[String] = Box(v = "hi")
  assertEqualInt(bi.echo(), 7, "Box[Int].echo")
  assertEqual(bs.echo(), "hi", "Box[String].echo")
}

test "a generic record method instantiated at a record type" {
  val bp: Box[Point] = Box(v = Point(x = 3, y = 4))
  val p = bp.echo()
  assertEqualInt(p.x + p.y, 7, "Box[Point].echo")
}

test "a nested generic call inside the specialised method" {
  val bi: Box[Int] = Box(v = 5)
  assertEqualInt(bi.twice().count, 2, "pair calls ident at T")
  assertEqualInt(bi.twice()[1], 5, "element")
}

test "two generic records calling the same generic do not collide" {
  val a: Box[Int] = Box(v = 1)
  val b: Other[String] = Other(v = "x")
  assertEqualInt(a.echo(), 1, "Box")
  assertEqual(b.echo(), "x", "Other")
}

ref record GBox[T] {
  var v: T
}

func setVia[T](x: inout T, b: in GBox[T], d: in T): Unit {
  x = d
}

test "a generic inout T bound from a generic record's field argument (#8370)" {
  val b: GBox[Int] = GBox(v = 1)
  setVia(b.v, b, 9)
  assertEqualInt(b.v, 9, "the field was assigned through inout T")
}

test "an enclosing type parameter as an explicit type argument (#8280)" {
  assertEqualInt(t3(4, 5), 4, "t3 at Int")
  assertEqual(t3("a", "b"), "a", "t3 at String")
}
