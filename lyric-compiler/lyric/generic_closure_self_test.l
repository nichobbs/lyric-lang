//! generic_closure_self_test.l — lambdas in generic contexts (#8284, #7792,
//! #8205, #7671, #8292).
//!
//! On `--target dotnet` a lambda was lifted to a static method of the
//! non-generic package class, where the type parameters of the member that
//! built it do not exist.  A lambda that read the receiver of a generic type
//! was rejected (F0048) or threw `TypeLoadException`, and a closure call whose
//! result is a type parameter stored the closure's `object` result into the
//! `T` slot without unboxing it, so a value-type `T` read garbage.  A lambda in
//! a member of a type with type parameters is now an instance method of a
//! closure class generic over those parameters, built at the member's own
//! `!0..!n`; the type checker spells the type of a function-valued local and
//! of a callee in a type parameter's name, so the call's result is unboxed to
//! it.
//!
//! Each case runs with a value-type and a reference-type instantiation.  The
//! cases that call a lambda after writing a `var` it captured are not run on
//! native, whose closures capture a variable's value (#7891), and neither is a
//! call to an `impl` method for a generic target, which native does not lower
//! yet.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/generic_closure_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/generic_closure_self_test.l
//!   lyric test --target native lyric-compiler/lyric/generic_closure_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.GenericClosureSelfTest

import Std.Core
import Std.Collections
import Std.Testing

// #8205: a closure returning `T` inside a generic record method.
record Holder[T] {
  tag: Int
  func viaVal(self: in Holder[T], v: in T): T {
    val y = v
    val f = { -> y }
    val seen: T = f()
    seen
  }
  func viaVar(self: in Holder[T], seed: in T, v: in T): T {
    var y = seed
    val f = { -> y }
    y = v
    val seen: T = f()
    seen
  }
  func viaParam(self: in Holder[T], v: in T): T {
    val f = { x: T -> x }
    f(v)
  }
}

// #8284 / #7792: lambdas reading the receiver of a generic record.
record Counter[T] {
  n: Int
  tag: T
  func viaSelf(self: in Counter[T]): Int {
    val f = { -> self.n + 1 }
    f()
  }
  func viaBare(self: in Counter[T]): Int {
    val f = { -> n + 2 }
    f()
  }
  func viaMe(self: in Counter[T]): Int {
    val me = self
    val f = { -> me.n + 3 }
    f()
  }
  func tagOf(self: in Counter[T]): T {
    val f = { -> tag }
    f()
  }
  func tagTwice(self: in Counter[T]): T {
    val g = { -> self.tagOf() }
    g()
  }
  func nested(self: in Counter[T]): T {
    val outer = { -> val inner = { -> tag }; inner() }
    outer()
  }
  func tagWith(self: in Counter[T], k: in Int): Int {
    val f = { x: Int -> x + k + n }
    f(1)
  }
}

record Box[T] {
  var value: T
  func get(self: in Box[T]): T {
    var r = self.value
    val f = { -> r = self.value }
    f()
    r
  }
}

interface Shows {
  func first(): Int
}

record Pair[T] {
  a: Int
  b: T
}

// A lambda in an `impl` method for a generic target.
impl[T] Shows for Pair[T] {
  func first(): Int {
    val f = { -> self.a * 2 }
    f()
  }
}

// A generic protected type's members: a lambda reading and writing fields.
protected type Cell[T] {
  var value: T
  var n: Int = 2
  func viaBare(): Int {
    val f = { -> n + 1 }
    f()
  }
  func getVia(): T {
    val f = { -> value }
    f()
  }
  entry setVia(v: in T): Unit {
    val f = { x: Int -> n = n + x }
    f(5)
    value = v
  }
  func count(): Int = n
}

// #7671: a closure reading a captured generic record's field, in a generic
// function.  The closure's type is annotated: the checker types a field read
// through a type parameter as unknown, so an unannotated closure's result has
// no type to unbox to on dotnet (#7671 stays open for that form).
record MyBox[T] {
  var value: T
}

func readViaTypedClosure[T](seed: in T): T {
  val box = MyBox(value = seed)
  val get: () -> T = { -> box.value }
  get()
}

// #8292: a closure called through a generic `List[(T) -> T]` parameter.
func runG[T](fs: in List[(T) -> T], x: in T): T {
  fs[0](x)
}

test "a closure returning T in a generic record method (#8205)" {
  val h: Holder[Int] = Holder(tag = 0)
  assertEqualInt(h.viaVal(7), 7, "Int val capture")
  assertEqualInt(h.viaParam(8), 8, "Int parameter")
  val hs: Holder[String] = Holder(tag = 0)
  assertEqual(hs.viaVal("b"), "b", "String val capture")
  assertEqual(hs.viaParam("c"), "c", "String parameter")
}

@cfg(not(target = "native"))
test "a closure returning a captured var of type T (#8205)" {
  val h: Holder[Int] = Holder(tag = 0)
  assertEqualInt(h.viaVar(1, 7), 7, "Int var capture")
  val hs: Holder[String] = Holder(tag = 0)
  assertEqual(hs.viaVar("a", "b"), "b", "String var capture")
}

test "a lambda reads the receiver of a generic record (#8284)" {
  val c: Counter[Int] = Counter(n = 10, tag = 5)
  assertEqualInt(c.viaSelf(), 11, "self.n")
  assertEqualInt(c.viaBare(), 12, "bare field")
  assertEqualInt(c.viaMe(), 13, "val me = self")
  assertEqualInt(c.tagOf(), 5, "T field")
  assertEqualInt(c.tagTwice(), 5, "sibling method through self")
  assertEqualInt(c.nested(), 5, "nested lambdas")
  assertEqualInt(c.tagWith(3), 14, "parameter, capture and field")
  val d: Counter[String] = Counter(n = 20, tag = "x")
  assertEqualInt(d.viaSelf(), 21, "self.n")
  assertEqualInt(d.viaBare(), 22, "bare field")
  assertEqualInt(d.viaMe(), 23, "val me = self")
  assertEqual(d.tagOf(), "x", "T field")
  assertEqual(d.tagTwice(), "x", "sibling method through self")
  assertEqual(d.nested(), "x", "nested lambdas")
}

@cfg(not(target = "native"))
test "a lambda writes a captured var from a T field of self (#7792)" {
  val b: Box[Int] = Box(value = 42)
  assertEqualInt(b.get(), 42, "Int")
  val s: Box[String] = Box(value = "hi")
  assertEqual(s.get(), "hi", "String")
}

@cfg(not(target = "native"))
test "a lambda in an impl method for a generic target reads self" {
  val p: Pair[Int] = Pair(a = 4, b = 9)
  assertEqualInt(p.first(), 8, "Int")
  val q: Pair[String] = Pair(a = 5, b = "s")
  assertEqualInt(q.first(), 10, "String")
}

test "lambdas in a generic protected type read and write its fields" {
  val c: Cell[Int] = Cell(value = 7)
  c.setVia(9)
  assertEqualInt(c.viaBare(), 8, "bare field")
  assertEqualInt(c.getVia(), 9, "T field")
  assertEqualInt(c.count(), 7, "field written by the lambda")
  val s: Cell[String] = Cell(value = "a")
  assertEqual(s.getVia(), "a", "T field")
  s.setVia("z")
  assertEqual(s.getVia(), "z", "T field after the entry")
}

test "a typed closure reads a captured generic record's field (#7671)" {
  assertEqualInt(readViaTypedClosure(42), 42, "Int")
  assertEqual(readViaTypedClosure("s"), "s", "String")
}

test "a closure called through a generic List[(T) -> T] (#8292)" {
  val k = 10
  val fs: List[(Int) -> Int] = [{ x: Int -> x + k }]
  assertEqualInt(runG(fs, 5), 15, "captured, named list")
  assertEqualInt(runG([{ x: Int -> x + k }], 5), 15, "captured, literal")
  assertEqualInt(runG([{ x: Int -> x + 1 }], 5), 6, "uncaptured")
  val suffix = "!"
  assertEqual(runG([{ s: String -> s + suffix }], "hi"), "hi!", "String")
}
