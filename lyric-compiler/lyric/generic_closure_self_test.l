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
//! it.  Where the checker cannot name the result's type, the `object` result is
//! unboxed where it is returned, stored or joined with a value of a type
//! parameter or value type.
//!
//! Most cases run with a value-type and a reference-type instantiation.  The
//! cases that call a lambda after writing a `var` it captured are not run on
//! native, whose closures capture a variable's value (#7891).  Nor are the
//! cases native rejects at compile time: a call to an `impl` method for a
//! generic target or to a record method with its own type parameters, which
//! native does not lower yet, and an unannotated closure whose result type the
//! type checker cannot name (a field read through a type parameter, a pattern
//! variable of one, an interface default's `self` call), which native reports
//! as N0007 and dotnet and the JVM type from the value.
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

@cfg(not(target = "native"))
func readViaClosure[T](seed: in T): T {
  val box = MyBox(value = seed)
  val get = { -> box.value }
  get()
}

// A closure reading a field through the receiver's generic field (H1).
@cfg(not(target = "native"))
record Outer[T] {
  inner: MyBox[T]
  func viaSelf(self: in Outer[T]): T {
    val g = { -> self.inner.value }
    g()
  }
  func viaBareInner(self: in Outer[T]): T {
    val g = { -> inner.value }
    g()
  }
}

// A closure capturing a pattern variable of type T.
@cfg(not(target = "native"))
record Src[T] {
  v: T
  func armSome(self: in Src[T], o: in Option[T]): T {
    match o {
      case Some(x) -> {
        val f = { -> x }
        f()
      }
      case None -> v
    }
  }
  func stmtArm(self: in Src[T], o: in Option[T]): T {
    var r = v
    match o {
      case Some(x) -> {
        val f = { -> x }
        r = f()
      }
      case None -> ()
    }
    r
  }
  func viaIf(self: in Src[T], o: in Option[T], useV: in Bool): T {
    val y = match o { case Some(x) -> x; case None -> v }
    if useV {
      v
    } else {
      val f = { -> y }
      f()
    }
  }
}

@cfg(not(target = "native"))
func genArm[T](o: in Option[T], d: in T): T {
  match o {
    case Some(x) -> {
      val y = x
      val f = { -> y }
      f()
    }
    case None -> d
  }
}

// A closure returning a `List` (P2).
func listOfG[T](x: in T): List[T] {
  val f = { -> val l: List[T] = newList(); l.add(x); l }
  f()
}

func listOfInt(x: in Int): List[Int] {
  val f = { y: Int -> val l: List[Int] = newList(); l.add(y); l }
  f(x)
}

// A lambda naming a method's own type parameter (M1).
@cfg(not(target = "native"))
record Plain {
  n: Int
  func withUParam[U](self: in Plain, u: in U): U {
    val f = { x: U -> x }
    f(u)
  }
  func mapTo[U](self: in Plain, x: in Int, f: in (Int) -> U): U {
    val g = { -> f(x) }
    g()
  }
}

@cfg(not(target = "native"))
record Both[T] {
  v: T
  func both[U](self: in Both[T], u: in U): T {
    val f = { x: U -> v }
    f(u)
  }
  func mapTo[U](self: in Both[T], f: in (T) -> U): U {
    val g = { -> f(v) }
    g()
  }
}

// A lambda in an interface default method reading the receiver (P3).
@cfg(not(target = "native"))
interface Getter {
  func raw(): Int
  func viaLamSelf(): Int {
    val f = { -> self.raw() + 1 }
    f()
  }
}

@cfg(not(target = "native"))
impl Getter for Plain {
  func raw(): Int = n
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

@cfg(not(target = "native"))
test "an unannotated closure reads a field through a type parameter (#7671)" {
  assertEqualInt(readViaClosure(42), 42, "Int")
  assertEqual(readViaClosure("s"), "s", "String")
  val o: Outer[Int] = Outer(inner = MyBox(value = 5))
  assertEqualInt(o.viaSelf(), 5, "self.inner.value")
  assertEqualInt(o.viaBareInner(), 5, "inner.value")
  val os: Outer[String] = Outer(inner = MyBox(value = "q"))
  assertEqual(os.viaSelf(), "q", "String self.inner.value")
}

@cfg(not(target = "native"))
test "a closure captures a pattern variable of type T" {
  val s: Src[Int] = Src(v = 4)
  val some: Option[Int] = Some(value = 8)
  val none: Option[Int] = None
  assertEqualInt(s.armSome(some), 8, "Some arm")
  assertEqualInt(s.armSome(none), 4, "None arm")
  assertEqualInt(s.stmtArm(some), 8, "assigned from the closure")
  assertEqualInt(s.viaIf(some, false), 8, "if branch")
  assertEqualInt(s.viaIf(some, true), 4, "other if branch")
  assertEqualInt(genArm(some, 1), 8, "generic function")
  val ss: Src[String] = Src(v = "d")
  assertEqual(ss.armSome(Some(value = "x")), "x", "String Some arm")
}

test "a closure returns a List" {
  assertEqualInt(listOfG(5).count, 1, "generic")
  assertEqualInt(listOfInt(5)[0], 5, "Int")
}

@cfg(not(target = "native"))
test "a lambda names a method's own type parameter" {
  // Read through `toString`: a method's own type parameter is erased, and a
  // call's result passed straight to an `Int` parameter is a separate gap.
  val p = Plain(n = 1)
  assertEqual(toString(p.withUParam(4)), "4", "Int")
  assertEqual(toString(p.withUParam("s")), "s", "String")
  assertEqual(toString(p.mapTo(4, { v: Int -> v * 3 })), "12", "unannotated closure local")
  val b: Both[Int] = Both(v = 7)
  assertEqualInt(b.both("x"), 7, "with the type's own")
  assertEqual(toString(b.mapTo({ v: Int -> v + 1 })), "8", "unannotated closure local, generic type")
}

@cfg(not(target = "native"))
test "a lambda in an interface default method reads the receiver" {
  val p = Plain(n = 8)
  assertEqualInt(p.viaLamSelf(), 9, "self.raw()")
}
