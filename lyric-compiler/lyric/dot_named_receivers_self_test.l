//! dot_named_receivers_self_test.l — runtime regression test for method calls
//! on dot-named functions (`func T.m(self: in T, ...)`) whose receiver is an
//! enum (#8254), a union (including a bare nullary case literal, #8478) or `Option` (#8037) or a generic record (#8037), and
//! for the bodies of dot-named record functions: an `async` one reading `self`
//! and awaited with method syntax or through the type (#8253), and one whose
//! lambda captures `self` (#8291).  Runs on every target.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/dot_named_receivers_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/dot_named_receivers_self_test.l
//!   lyric test --target native lyric-compiler/lyric/dot_named_receivers_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.DotNamedReceiversSelfTest

import Std.Core
import Std.Collections
import Std.Testing

enum Color {
  case Red
  case Green
}

func Color.num(self: in Color): Int {
  match self {
    case Red -> 1
    case Green -> 2
  }
}

func Color.plus(self: in Color, k: in Int): Int = self.num() + k

func Color.bump(self: in Color, total: inout Int): Unit {
  total = total + self.num()
}

union Shape {
  case Circle(r: Int)
  case Square(side: Int)
  case Empty
}

func Shape.size(self: in Shape): Int {
  match self {
    case Circle(r) -> r * 3
    case Square(side) -> side * side
    case Empty -> 0
  }
}

func Shape.scaled(self: in Shape, by: in Int): Int = self.size() * by

func Shape.tagged(self: in Shape, tag: in String): String = tag + toString(self.size())

func Option.orDefault[T](self: in Option[T], d: in T): T {
  match self {
    case Some(v) -> v
    case None -> d
  }
}

record Cell[T] {
  v: T
}

func Cell.get[T](self: in Cell[T]): T = self.v

func Cell.pick[T](self: in Cell[T], other: in T): T = self.v

record Acc {
  n: Int
}

async func Acc.aGet(self: in Acc, k: in Int): Int {
  self.n + k
}

async func viaMethod(): Int {
  val a = Acc(n = 100)
  await a.aGet(3)
}

async func viaType(): Int {
  val a = Acc(n = 200)
  await Acc.aGet(a, 4)
}

async func five(): Int {
  5
}

async func viaOptionAwaitArg(): Int {
  val o: Option[Int] = None
  o.orDefault(await five())
}

async func viaUnionAwaitArg(): Int {
  val s: Shape = Square(side = 2)
  s.scaled(await five())
}

async func viaEnumAwaitArg(): Int {
  Color.Green.plus(await five())
}

record Live {
  total: Int
}

func Live.calc(self: in Live): Int {
  val f = { -> self.total + 0 }
  f()
}

record Named {
  label: String
}

func Named.shown(self: in Named): String {
  val f = { -> self.label + "!" }
  f()
}

test "an enum receiver with no parameters" {
  val red = Color.Red
  assertEqualInt(red.num(), 1, "Red")
  assertEqualInt(Color.Green.num(), 2, "Green literal")
  assertEqualInt(Color.num(red), 1, "type-qualified")
}

test "an enum receiver with parameters and an inout parameter" {
  val g = Color.Green
  assertEqualInt(g.plus(40), 42, "plus")
  var total = 10
  g.bump(total)
  assertEqualInt(total, 12, "bump")
  Color.Red.bump(total)
  assertEqualInt(total, 13, "bump on a literal")
}

test "a union receiver" {
  val c = Circle(r = 4)
  assertEqualInt(c.size(), 12, "size")
  assertEqualInt(Square(side = 3).scaled(2), 18, "scaled")
  val none: Shape = Empty
  assertEqual(none.tagged("n="), "n=0", "tagged on a nullary case")
  assertEqual(Empty.tagged("n="), "n=0", "tagged on the bare nullary case literal (#8478)")
  assertEqualInt(Empty.scaled(5), 0, "scaled on the bare nullary case literal (#8478)")
  val s: Shape = Square(side = 5)
  assertEqual(s.tagged("s"), "s25", "tagged")
}

test "an Option receiver" {
  val some: Option[Int] = Some(value = 7)
  val none: Option[Int] = None
  assertEqualInt(some.orDefault(1), 7, "Some")
  assertEqualInt(none.orDefault(1), 1, "None")
}

test "a generic record receiver" {
  val c = Cell(v = 9)
  assertEqualInt(c.get(), 9, "get")
  assertEqual(Cell(v = "x").get(), "x", "String")
  assertEqualInt(c.pick(5), 9, "pick")
}

test "an async dot-named method reading self" {
  assertEqualInt(await viaMethod(), 103, "method syntax")
  assertEqualInt(await viaType(), 204, "through the type")
}

test "an await in the arguments of a method call on a union, Option or enum" {
  assertEqualInt(await viaOptionAwaitArg(), 5, "None")
  assertEqualInt(await viaUnionAwaitArg(), 20, "union")
  assertEqualInt(await viaEnumAwaitArg(), 7, "enum")
}

test "a lambda capturing self in a dot-named method" {
  assertEqualInt(Live(total = 4).calc(), 4, "value-type field")
  assertEqual(Named(label = "hi").shown(), "hi!", "reference-type field")
}
