//! dot_named_byref_self_test.l — runtime regression test for `out`/`inout`
//! arguments of dot-named methods (`func T.m(self, x: inout ...)`, #8183), on
//! every target.
//!
//! A method call written on a dot-named function passes its `out`/`inout`
//! arguments by reference exactly as the type-qualified call does (docs/01
//! §5.2): the middle end rewrites such a call into a plain call of the
//! function, the receiver first (`Lyric.Pipeline`'s `byref_receivers.l`).
//! Before that, `a.into(y, 3)` passed `y` by value: InvalidProgramException
//! on dotnet, VerifyError on the JVM.  This file covers the shapes around
//! that call: both call forms, `out` and `inout`, named arguments in and out
//! of order (evaluated in source order, D171), every kind of place (a local,
//! a field, a nested field, an array element, a caller's `inout` parameter),
//! an `inout` receiver beside an `inout` argument, generic functions and
//! records at value and reference types, union receivers, a call's value in
//! expression position and as a `?` operand, and, for comparison, the same
//! parameters on an interface method called through the interface.
//!
//! A captured `var` passed by reference inside a closure is covered, on
//! dotnet and the JVM, by `inout_receiver_closure_self_test.l`; native
//! rejects it with N0024 until its closures share a captured variable's cell
//! (#7891), which `llvm_inout_self_test.l` asserts.  Calls into another package and
//! a restored dependency are covered by `scripts/ci/inout-receiver-e2e.sh`.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/dot_named_byref_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/dot_named_byref_self_test.l
//!   lyric test --target native lyric-compiler/lyric/dot_named_byref_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.DotNamedByrefSelfTest

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

record Acc {
  n: Int
}

func mkAcc(n: in Int): Acc {
  trace.add("recv")
  Acc(n = n)
}

func Acc.into(self: in Acc, x: inout Int, j: in Int): Unit {
  x = self.n + j
}

func Acc.setOut(self: in Acc, x: out Int, j: in Int): Unit {
  x = self.n * j
}

// Returns twice the old `a`, adds `n` to `a` and stores the old `a` in `b`.
func Acc.both(self: in Acc, a: inout Int, b: out Int): Int {
  val prev = a
  a = a + self.n
  b = prev
  prev * 2
}

func Acc.addGet(self: in Acc, x: inout Int): Int {
  x = x + self.n
  x
}

// Passes its own `inout` parameter on, with method syntax and through the
// type.
func Acc.twice(self: in Acc, x: inout Int): Unit {
  self.into(x, 1)
  Acc.into(self, x, x)
}

func Acc.tryInto(self: in Acc, x: inout Int, j: in Int): Result[Int, String] {
  if j < 0 {
    return Err(error = "negative: " + toString(j))
  }
  x = self.n + j
  Ok(value = x * 2)
}

func runTry(j: in Int, y: inout Int): Result[Int, String] {
  val a = Acc(n = 100)
  val r = a.tryInto(y, j)? + 1
  val s = Acc.tryInto(a, j = j + 1, x = y)?
  Ok(value = r * 1000 + s)
}

func viaParam(q: inout Int, a: in Acc): Unit {
  a.into(q, 1)
  Acc.into(a, q, q)
}

record Cell {
  var f: Int
}

record Nest {
  var c: Cell
}

// A value record (no `var` field) whose receiver is replaced (D157).
record Ctr {
  n: Int

  // Swaps the count with `x`.
  func swap(self: inout Ctr, x: inout Int): Unit {
    val t = n
    self = Ctr(n = x)
    x = t
  }
}

// Returns the old count, adds `x` to it and stores the old count in `x`.
func Ctr.take(self: inout Ctr, x: inout Int): Int {
  val prev = self.n
  self = Ctr(n = self.n + x)
  x = prev
  prev
}

func Ctr.give(self: inout Ctr, x: out Int, d: in Int): Unit {
  x = self.n
  self = Ctr(n = self.n + d)
}

record Hold {
  var c: Ctr
  var k: Int
}

record Box[T] {
  v: T
}

func Box.put[T](self: in Box[T], x: inout T): Unit {
  x = self.v
}

func Box.emit[T](self: in Box[T], x: out T): Unit {
  x = self.v
}

// Swaps the boxed value with `x` and returns the old boxed value.
func Box.swapIn[T](self: inout Box[T], x: inout T): T {
  val prev = self.v
  self = Box(v = x)
  x = prev
  prev
}

record Pt {
  x: Int
  y: Int
}

union Shape {
  case Sq(side: Int)
  case Circ(r: Int)
}

func Shape.measure(self: in Shape, area: out Int): Bool {
  match self {
    case Sq(s) -> {
      area = s * s
      true
    }
    case Circ(r) -> {
      area = 3 * r * r
      false
    }
  }
}

interface Sink {
  func put(self: in Self, x: inout Int, j: in Int): Unit
  func get(self: in Self, x: out Int, s: inout String): Int
}

impl Sink for Acc {
  func put(self: in Self, x: inout Int, j: in Int): Unit {
    x = self.n + j
  }

  func get(self: in Self, x: out Int, s: inout String): Int {
    x = self.n
    s = s + "!"
    self.n * 2
  }
}

// A by-value implementer, reached through its vtable thunk.
impl Sink for Pt {
  func put(self: in Self, x: inout Int, j: in Int): Unit {
    x = self.x * 10 + j
  }

  func get(self: in Self, x: out Int, s: inout String): Int {
    x = self.y
    s = s + "?"
    self.x + self.y
  }
}

func throughSink(k: in Sink, y: inout Int, s: inout String): Int {
  k.put(y, 3)
  var w = 0
  val r = k.get(s = s, x = w)
  r * 1000 + w
}

test "an inout argument, with method syntax and through the type" {
  val a = Acc(n = 100)
  var y = 0
  a.into(y, 3)
  assertEqualInt(y, 103, "a.into(y, 3)")
  Acc.into(a, y, 4)
  assertEqualInt(y, 104, "Acc.into(a, y, 4)")
}

test "an out argument, with method syntax and through the type" {
  val a = Acc(n = 5)
  var y = 0
  a.setOut(y, 3)
  assertEqualInt(y, 15, "a.setOut(y, 3)")
  Acc.setOut(a, y, 4)
  assertEqualInt(y, 20, "Acc.setOut(a, y, 4)")
}

test "named arguments in and out of order" {
  val a = Acc(n = 100)
  var y = 0
  a.into(x = y, j = 1)
  assertEqualInt(y, 101, "in order")
  a.into(j = 2, x = y)
  assertEqualInt(y, 102, "out of order")
  Acc.into(a, j = 3, x = y)
  assertEqualInt(y, 103, "through the type, out of order")
  var z = 0
  a.setOut(j = 2, x = z)
  assertEqualInt(z, 200, "an out argument, out of order")
}

test "the receiver and named arguments run in source order" {
  val start = trace.count
  var y = 0
  mkAcc(10).into(j = note("j", 1), x = y)
  assertEqualInt(y, 11, "method syntax")
  assertEqual(since(start), "recv,j", "method syntax order")
  val s2 = trace.count
  Acc.into(mkAcc(20), j = note("j", 2), x = y)
  assertEqualInt(y, 22, "through the type")
  assertEqual(since(s2), "recv,j", "through the type order")
}

test "an argument reading the by-reference place sees its value before the call" {
  val a = Acc(n = 100)
  var y = 5
  a.into(j = y, x = y)
  assertEqualInt(y, 105, "j read before the call")
}

test "inout and out together, the value in expression position" {
  val a = Acc(n = 10)
  var y = 1
  var w = 0
  val z = a.both(y, w) + 1
  assertEqualInt(z, 3, "result")
  assertEqualInt(y, 11, "inout")
  assertEqualInt(w, 1, "out")
  val z2 = Acc.both(a, b = w, a = y) * 10
  assertEqualInt(z2, 220, "named result")
  assertEqualInt(y, 21, "named inout")
  assertEqualInt(w, 11, "named out")
}

test "nested calls and calls in branches" {
  val a = Acc(n = 10)
  var y = 1
  var z = 2
  a.into(y, a.addGet(z))
  assertEqualInt(z, 12, "inner call")
  assertEqualInt(y, 22, "outer call")
  val w = if y > 0 { a.addGet(y) } else { 0 }
  assertEqualInt(w, 32, "if branch")
  val m = match z { case 12 -> a.addGet(z) * 2; case _ -> 0 }
  assertEqualInt(m, 44, "match arm")
}

test "a dot-named method passing its own inout parameter on" {
  val a = Acc(n = 10)
  var y = 0
  a.twice(y)
  assertEqualInt(y, 21, "a.twice(y)")
}

test "a field and a nested field as the place" {
  val a = Acc(n = 100)
  var c = Cell(f = 0)
  a.into(c.f, 3)
  assertEqualInt(c.f, 103, "method syntax")
  Acc.into(a, c.f, 4)
  assertEqualInt(c.f, 104, "through the type")
  a.setOut(c.f, 2)
  assertEqualInt(c.f, 200, "out")
  val cv = Cell(f = 0)
  a.into(cv.f, 5)
  assertEqualInt(cv.f, 105, "a field of a val")
  var n = Nest(c = Cell(f = 0))
  a.into(n.c.f, 6)
  assertEqualInt(n.c.f, 106, "nested, method syntax")
  Acc.into(a, x = n.c.f, j = 7)
  assertEqualInt(n.c.f, 107, "nested, through the type")
}

test "an array element as the place" {
  val a = Acc(n = 100)
  var arr: array[3, Int] = [1, 2, 3]
  a.into(arr[1], 8)
  assertEqualInt(arr[1], 108, "method syntax")
  var i = 2
  Acc.into(a, arr[i], 9)
  assertEqualInt(arr[2], 109, "through the type, computed index")
  a.setOut(j = 3, x = arr[0])
  assertEqualInt(arr[0], 300, "out, named")
  assertEqualInt(arr[1], 108, "other element untouched")
}

test "the caller's inout parameter as the place" {
  val a = Acc(n = 100)
  var y = 0
  viaParam(y, a)
  assertEqualInt(y, 201, "viaParam")
}

test "an inout receiver beside an inout argument" {
  var c = Ctr(n = 10)
  var y = 5
  val r = c.take(y)
  assertEqualInt(r, 10, "result")
  assertEqualInt(c.n, 15, "receiver")
  assertEqualInt(y, 10, "argument")
  Ctr.take(c, y)
  assertEqualInt(c.n, 25, "through the type, receiver")
  assertEqualInt(y, 15, "through the type, argument")
  c.take(x = y)
  assertEqualInt(c.n, 40, "named")
  var d = Ctr(n = 1)
  var o = 0
  d.give(d = 2, x = o)
  assertEqualInt(o, 1, "out argument")
  assertEqualInt(d.n, 3, "receiver beside an out argument")
}

test "a record-body inout method with an inout argument" {
  var r = Ctr(n = 1)
  var y = 2
  r.swap(y)
  assertEqualInt(r.n, 2, "receiver")
  assertEqualInt(y, 1, "argument")
  Ctr.swap(r, y)
  assertEqualInt(r.n, 1, "through the type, receiver")
  assertEqualInt(y, 2, "through the type, argument")
}

test "receiver and argument are fields, or elements, of one value" {
  var h = Hold(c = Ctr(n = 7), k = 3)
  h.c.take(h.k)
  assertEqualInt(h.c.n, 10, "receiver field")
  assertEqualInt(h.k, 7, "argument field")
  var cs: array[2, Ctr] = [Ctr(n = 1), Ctr(n = 2)]
  var ks: array[2, Int] = [10, 20]
  cs[1].take(ks[0])
  assertEqualInt(cs[1].n, 12, "receiver element")
  assertEqualInt(ks[0], 2, "argument element")
}

test "a generic dot-named method at a value type" {
  val b = Box(v = 42)
  var x = 0
  b.put(x)
  assertEqualInt(x, 42, "method syntax")
  var z = 1
  Box.put(b, z)
  assertEqualInt(z, 42, "through the type")
  var w = 0
  b.emit(w)
  assertEqualInt(w, 42, "out")
}

test "a generic dot-named method at reference and record types" {
  val b = Box(v = "hi")
  var s = ""
  b.put(s)
  assertEqual(s, "hi", "String, method syntax")
  var t = ""
  Box.put(b, x = t)
  assertEqual(t, "hi", "String, through the type")
  val bp = Box(v = Pt(x = 1, y = 2))
  var p = Pt(x = 0, y = 0)
  bp.put(p)
  assertEqualInt(p.y, 2, "record")
}

test "a generic inout receiver beside an inout argument" {
  var b = Box(v = 1)
  var x = 2
  val r = b.swapIn(x) + 100
  assertEqualInt(r, 101, "result")
  assertEqualInt(b.v, 2, "receiver")
  assertEqualInt(x, 1, "argument")
  var bs = Box(v = "a")
  var s = "b"
  Box.swapIn(bs, s)
  assertEqual(bs.v, "b", "String receiver")
  assertEqual(s, "a", "String argument")
}

test "a union receiver with an out argument" {
  var area = 0
  val s: Shape = Sq(side = 4)
  assertTrue(s.measure(area), "Sq")
  assertEqualInt(area, 16, "Sq area")
  assertFalse(Shape.measure(Circ(r = 2), area), "Circ")
  assertEqualInt(area, 12, "Circ area")
}

test "a field receiver with a sibling field as the argument" {
  var h = Hold(c = Ctr(n = 5), k = 0)
  val r = h.c.take(h.k) + 1
  assertEqualInt(r, 6, "result")
  assertEqualInt(h.c.n, 5, "receiver")
  assertEqualInt(h.k, 5, "argument")
}

test "a dot-named method returning Result as a ? operand" {
  var y = 0
  match runTry(1, y) {
    case Ok(v) -> assertEqualInt(v, 203204, "value")
    case Err(e) -> assertTrue(false, "unexpected error: " + e)
  }
  assertEqualInt(y, 102, "written by both calls")
  var z = 7
  match runTry(-5, z) {
    case Ok(_) -> assertTrue(false, "expected the ? to return early")
    case Err(e) -> assertEqual(e, "negative: -5", "error passed through")
  }
  assertEqualInt(z, 7, "untouched")
}

test "out and inout parameters of an interface method, called through the interface" {
  val a = Acc(n = 100)
  var y = 0
  a.put(y, 1)
  assertEqualInt(y, 101, "direct")
  a.put(j = 2, x = y)
  assertEqualInt(y, 102, "direct, named")
  var s = "a"
  assertEqualInt(throughSink(a, y, s), 200100, "through the interface")
  assertEqualInt(y, 103, "inout through the interface")
  assertEqual(s, "a!", "inout String through the interface")
  assertEqualInt(throughSink(Pt(x = 4, y = 5), y, s), 9005, "a by-value implementer")
  assertEqualInt(y, 43, "inout through a vtable thunk")
  assertEqual(s, "a!?", "inout String through a vtable thunk")
}

test "a field and an array element through the interface, in source order" {
  val k: Sink = Acc(n = 100)
  var arr: array[3, Int] = [1, 2, 3]
  var c = Cell(f = 0)
  val start = trace.count
  k.put(arr[note("i", 1)], 3)
  k.put(c.f, 4)
  k.put(j = note("j", 5), x = arr[note("k", 2)])
  assertEqualInt(arr[1], 103, "element")
  assertEqualInt(c.f, 104, "field")
  assertEqualInt(arr[2], 105, "element, named out of order")
  assertEqualInt(arr[0], 1, "other element untouched")
  assertEqual(since(start), "i,j,k", "order")
}
