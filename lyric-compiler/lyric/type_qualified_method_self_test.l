//! type_qualified_method_self_test.l — runtime regression test for a call
//! through a type, `T.m(x, args)`, of a method declared in the type's body
//! (D181), on every target.
//!
//! A call through the type binds what the method call `x.m(args)` binds:
//! the method in the type's body, when it takes the arguments.  The middle
//! end writes the call as the method call for the backends, which have no
//! function `T.m` for a body method.  Before, `Bag.one(b)` stopped with an
//! internal error (T0120) in MSIL codegen, and on the JVM for a method with
//! arguments.  This file covers a method with and without arguments, a
//! receiver that is a call result, a generic record's method and a method
//! with its own type parameter (bare, and inside a `List`, an `Option`, a
//! tuple and a function type, on a generic and a non-generic record), the
//! type named through its own package, an `inout` receiver, named arguments
//! in and out of order with their evaluation order, a defaulted argument,
//! and the type named through an alias.  Calls into another package and a restored
//! dependency are covered by `scripts/ci/inout-receiver-e2e.sh`.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/type_qualified_method_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/type_qualified_method_self_test.l
//!   lyric test --target native lyric-compiler/lyric/type_qualified_method_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.TypeQualifiedMethodSelfTest

import Std.Core
import Std.Collections
import Std.Testing

val trace: List[String] = newList()

func note(s: in String, v: in Int): Int {
  trace.add(s)
  v
}

// The evaluations logged since `start`, comma-separated.
func since(start: in Int): String {
  var acc = ""
  var i = start
  while i < trace.count {
    acc = if acc.length == 0 { trace[i] } else { acc + "," + trace[i] }
    i = i + 1
  }
  acc
}

record Bag {
  n: Int

  func one(self: in Bag): Int = self.n

  func two(self: in Bag, x: in Int, y: in Int): Int = self.n * 100 + x * 10 + y

  func scaled(self: in Bag, by: in Int = 10): Int = self.n * by

  func set(self: inout Bag, v: in Int): Unit {
    self = Bag(n = v)
  }
}

record Box[T] {
  v: T

  func get(self: in Box[T]): T = self.v

  func pairWith[U](self: in Box[T], u: in U): U = u

  func listOf[U](self: in Box[T], u: in U): List[U] {
    val l: List[U] = newList()
    l.add(u)
    l
  }

  func optOf[U](self: in Box[T], u: in U): Option[U] = Some(value = u)

  func pairOf[U](self: in Box[T], u: in U): (T, U) = (self.v, u)

  func mapV[U](self: in Box[T], f: in (T) -> U): U = f(self.v)

  func orElse[U](self: in Box[T], o: in Option[U], d: in U): U = match o { case Some(x) -> x; case None -> d }
}

record Tag {
  k: Int

  func echo[U](self: in Tag, u: in U): U = u

  func listOf[U](self: in Tag, u: in U): List[U] {
    val l: List[U] = newList()
    l.add(u)
    l
  }

  func optOf[U](self: in Tag, u: in U): Option[U] = Some(value = u)

  func mapK[U](self: in Tag, f: in (Int) -> U): U = f(self.k)
}

alias Sack = Bag

func mkBag(n: in Int): Bag {
  trace.add("recv")
  Bag(n = n)
}

test "a method with and without arguments" {
  val b = Bag(n = 5)
  assertEqualInt(Bag.one(b), 5, "no arguments")
  assertEqualInt(Bag.two(b, 1, 2), 512, "two arguments")
  assertEqualInt(Bag.one(b), b.one(), "the same as the method call")
}

test "a receiver that is a call result" {
  val t0 = trace.count
  assertEqualInt(Bag.one(mkBag(7)), 7, "value")
  assertEqual(since(t0), "recv", "the receiver runs once")
}

test "a generic record's method and a method with its own type parameter" {
  val bx = Box(v = "boxed")
  assertEqual(Box.get(bx), "boxed", "a String instance")
  val by = Box(v = 42)
  assertEqualInt(Box.get(by), 42, "an Int instance")
  assertEqualInt(Box.pairWith(bx, 9), 9, "the method's own type parameter")
  assertEqualInt(bx.pairWith(9), Box.pairWith(bx, 9), "the same as the method call")
  assertEqual(Box.pairWith(by, "s"), "s", "a reference type argument")
}

test "a method's own type parameter inside a List, an Option, a tuple and a function type" {
  val bx = Box(v = "s")
  assertEqualInt(bx.listOf(2)[0] + 1, 3, "a List of it, as a method call")
  assertEqualInt(Box.listOf(bx, 4)[0], 4, "through the type")
  assertEqual(Box.listOf(bx, "r")[0], "r", "a reference type argument")
  val o = match bx.optOf(5) { case Some(x) -> x + 1; case None -> 0 }
  assertEqualInt(o, 6, "an Option of it")
  val (pv, pu) = Box.pairOf(bx, 7)
  assertEqual(pv, "s", "a tuple of it, the record's part")
  assertEqualInt(pu + 1, 8, "a tuple of it, its part")
  val len: (String) -> Int = { s -> s.length }
  assertEqualInt(bx.mapV(len) + 1, 2, "a function returning it")
  assertEqualInt(Box.orElse(bx, None, 9) + 1, 10, "an Option of it as a parameter")
}

test "a non-generic record's method with its own type parameter" {
  val t = Tag(k = 3)
  assertEqualInt(t.echo(4) + 1, 5, "the method call")
  assertEqualInt(Tag.echo(t, 6) + 1, 7, "through the type")
  assertEqual(t.echo("e"), "e", "a reference type argument")
  assertEqualInt(Tag.listOf(t, 8)[0] + 1, 9, "a List of it")
  val o = match t.optOf(10) { case Some(x) -> x; case None -> 0 }
  assertEqualInt(o, 10, "an Option of it")
  val dbl: (Int) -> Int = { n -> n * 2 }
  assertEqualInt(Tag.mapK(t, dbl), 6, "a function returning it")
}

test "the type named through its own package" {
  val b = Bag(n = 5)
  assertEqualInt(Lyric.TypeQualifiedMethodSelfTest.Bag.two(b, 1, 2), 512, "positional")
  assertEqualInt(Lyric.TypeQualifiedMethodSelfTest.Bag.two(b, y = 2, x = 1), 512, "named")
  assertEqualInt(Lyric.TypeQualifiedMethodSelfTest.Bag.one(b), 5, "no arguments")
}

test "an inout receiver" {
  var b = Bag(n = 1)
  Bag.set(b, 9)
  assertEqualInt(b.n, 9, "written through the receiver")
}

test "named arguments in and out of order run in source order" {
  val t0 = trace.count
  val r = Bag.two(mkBag(5), y = note("y", 2), x = note("x", 1))
  assertEqualInt(r, 512, "value")
  assertEqual(since(t0), "recv,y,x", "order")
  val t1 = trace.count
  assertEqualInt(Bag.two(mkBag(3), note("x", 4), y = note("y", 5)), 345, "positional then named")
  assertEqual(since(t1), "recv,x,y", "mixed order")
}

test "a defaulted argument" {
  val b = Bag(n = 2)
  assertEqualInt(Bag.scaled(b), 20, "the default")
  assertEqualInt(Bag.scaled(b, by = 3), 6, "named")
}

test "the type named through an alias" {
  val b = Bag(n = 4)
  assertEqualInt(Sack.one(b), 4, "an alias of the record")
  assertEqualInt(Sack.two(b, 0, 1), 401, "with arguments")
}
