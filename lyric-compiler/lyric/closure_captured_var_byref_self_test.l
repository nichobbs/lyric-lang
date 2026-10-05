//! closure_captured_var_byref_self_test.l — dual-target runtime regression
//! test for passing a closure-captured `var` as an `out`/`inout` argument
//! (#8189).
//!
//! A `var` that a closure captures is hoisted to a one-element heap cell
//! shared by the closure and the enclosing scope (docs/01 §5.4: closures
//! capture `var` bindings by reference), so the variable's slot holds the
//! cell, not the value.  The by-reference argument lowering still treated the
//! slot as the value: on `--target dotnet` it passed the address of the slot
//! holding the cell reference as an `int32&`, so the callee's write corrupted
//! memory (`AccessViolationException`); on `--target jvm` it copied the cell
//! array into a holder and stored the callee's `int` result back into the
//! slot holding the cell (`VerifyError`).  The argument now denotes the
//! cell's element: `ldelema` on dotnet, and on the JVM the cell itself is
//! passed as the callee's holder array, so the closure sees each write the
//! callee makes while the call is still running, and the callee's caller sees
//! each write the closure makes.  On dotnet that holds for every type because
//! a captured record, union, generic or collection `var` has a cell of its own
//! type, not an `object[]` (#8199); the generic-receiver case is #8182.
//!
//! Every closure-call result is bound with an explicit annotation to stay
//! clear of the unrelated MSIL unannotated-closure-result bug (#7711).
//!
//!   lyric test --target dotnet lyric-compiler/lyric/closure_captured_var_byref_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/closure_captured_var_byref_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.ClosureCapturedVarByrefSelfTest

import Std.Core
import Std.Testing

record Box {
  var n: Int
}

union Shape {
  case Circle(r: Int)
  case Square(s: Int)
}

record Gen[T] {
  v: T
}

record Holder[T] {
  tag: Int

  func put(self: in Holder[T], x: inout T, v: in T): Unit {
    x = v
  }
}

interface Swapper {
  func takeFrom(self: in Self, other: inout Self, w: in () -> Unit): Unit
  func giveTo(self: in Self, other: inout Self): Unit
}

record Cell {
  n: Int
}

// `other: inout Self` keeps the interface slot's erased `object&` ABI.
impl Swapper for Cell {
  func takeFrom(self: in Self, other: inout Self, w: in () -> Unit): Unit {
    w()
  }

  func giveTo(self: in Self, other: inout Self): Unit {
    other = Cell(n = 6)
  }
}

// A same-named method with a typed `inout`: only the receiver's type tells
// it from `Swapper.takeFrom`.
record Other {
  k: Int

  func takeFrom(self: in Other, x: inout Cell, w: in () -> Unit): Unit {
    w()
  }
}

async func asyncHelper(): Int {
  1
}

async func asyncSwap(): Int {
  val s = Cell(n = 0)
  var c = Cell(n = 1)
  val w = { -> c = Cell(n = 5) }
  val k = await asyncHelper()
  s.takeFrom(c, w)
  val k2 = await asyncHelper()
  c.n + k + k2 - 2
}

func setCell(c: inout Cell, n: in Int): Unit {
  c = Cell(n = n)
}

func area(s: in Shape): Int {
  match s {
    case Circle(r) -> r
    case Square(q) -> q * 100
  }
}

func optVal(o: in Option[Int]): Int {
  match o {
    case Some(v) -> v
    case None -> 0
  }
}

func resVal(r: in Result[Int, String]): Int {
  match r {
    case Ok(v) -> v
    case Err(_) -> -1
  }
}

// Runs the closure, which rebinds the caller's variable, during the call.
func touchBox(b: inout Box, w: in () -> Unit): Unit {
  w()
}

func touchShape(s: inout Shape, w: in () -> Unit): Unit {
  w()
}

func touchOpt(o: inout Option[Int], w: in () -> Unit): Unit {
  w()
}

func touchRes(r: inout Result[Int, String], w: in () -> Unit): Unit {
  w()
}

func touchGen(g: inout Gen[Int], w: in () -> Unit): Unit {
  w()
}

func touchList(xs: inout List[Int], w: in () -> Unit): Unit {
  w()
}

func touchSlice(xs: inout slice[Int], w: in () -> Unit): Unit {
  w()
}

// Writes the argument, then reads it back through the closure during the call.
func setBoxRead(b: inout Box, f: in () -> Int): Int {
  b = Box(n = 9)
  f()
}

func setStrRead(s: inout String, f: in () -> String): String {
  s = "new"
  f()
}

func setShapeRead(s: inout Shape, f: in () -> Int): Int {
  s = Square(s = 3)
  f()
}

func setOptRead(o: inout Option[Int], f: in () -> Int): Int {
  o = Some(8)
  f()
}

func setResRead(r: inout Result[Int, String], f: in () -> Int): Int {
  r = Ok(4)
  f()
}

func setGenRead(g: inout Gen[Int], f: in () -> Int): Int {
  g = Gen(v = 6)
  f()
}

func setListRead(xs: inout List[Int], f: in () -> Int): Int {
  val ys: List[Int] = newList()
  ys.add(1)
  ys.add(2)
  ys.add(3)
  xs = ys
  f()
}

func setSliceRead(xs: inout slice[Int], f: in () -> Int): Int {
  xs = [7, 7, 7, 7]
  f()
}

func setTo(x: inout Int, v: in Int): Unit {
  x = v
}

func bump(x: inout Int): Unit {
  x = x + 1
}

func produce(x: out Int, v: in Int): Unit {
  x = v
}

func setFrom(v: in Int, x: inout Int): Unit {
  x = v
}

func setLong(x: inout Long, v: in Long): Unit {
  x = v
}

func appendTo(s: inout String, suffix: in String): Unit {
  s = s + suffix
}

func replaceBox(b: inout Box, n: in Int): Unit {
  b = Box(n = n)
}

func flip(b: inout Bool): Unit {
  b = not b
}

func assignAny[T](x: inout T, v: in T): Unit {
  x = v
}

// Writes the argument, then calls `f` while the call is still running.
func setThenRead(x: inout Int, v: in Int, f: in () -> Int): Int {
  x = v
  f()
}

func okInt(v: in Int): Result[Int, String] {
  Ok(v)
}

func propagateCase(): Result[Int, String] {
  var x = 1
  val f = { -> x }
  setFrom(okInt(6)?, x)
  val seen: Int = f()
  Ok(x * 100 + seen)
}

test "inout captured Int: the closure sees the callee's write (#8189)" {
  var x = 1
  val f = { -> x }
  setTo(x, 5)
  val seen: Int = f()
  assertEqualInt(x, 5, "x after setTo")
  assertEqualInt(seen, 5, "f() after setTo")
}

test "out captured Int" {
  var x = 1
  val f = { -> x }
  produce(x, 42)
  val seen: Int = f()
  assertEqualInt(x, 42, "x after produce")
  assertEqualInt(seen, 42, "f() after produce")
}

test "inout captured Int read and written by the callee" {
  var x = 10
  val f = { -> x }
  bump(x)
  bump(x)
  val seen: Int = f()
  assertEqualInt(x, 12, "x after two bumps")
  assertEqualInt(seen, 12, "f() after two bumps")
}

test "mutation through the closure is visible before and after the call" {
  var x = 1
  val read = { -> x }
  val write = { v: Int -> x = v }
  write(2)
  val before: Int = read()
  assertEqualInt(before, 2, "f() after closure write, before the call")
  assertEqualInt(x, 2, "x after closure write, before the call")
  setTo(x, 5)
  val mid: Int = read()
  assertEqualInt(mid, 5, "f() after the call")
  write(7)
  val after: Int = read()
  assertEqualInt(after, 7, "f() after a closure write following the call")
  assertEqualInt(x, 7, "x after a closure write following the call")
}

test "two closures capturing the same var" {
  var x = 1
  val f = { -> x }
  val g = { -> x * 10 }
  setTo(x, 3)
  val a: Int = f()
  val b: Int = g()
  assertEqualInt(a, 3, "first closure")
  assertEqualInt(b, 30, "second closure")
}

test "the callee's write is visible to the closure during the call" {
  var x = 1
  val f = { -> x }
  val seen = setThenRead(x, 8, f)
  assertEqualInt(seen, 8, "closure called inside the callee")
  assertEqualInt(x, 8, "x after the call")
}

test "captured var passed by ref inside the lambda body" {
  var x = 1
  val h = { -> setTo(x, 9) }
  h()
  assertEqualInt(x, 9, "x after the lambda's by-ref call")
  val k = { -> bump(x) }
  k()
  k()
  assertEqualInt(x, 11, "x after two by-ref bumps inside a lambda")
}

test "captured var passed by ref from a nested lambda" {
  var x = 1
  val read = { -> x }
  val outer = { -> val inner = { -> setTo(x, 12) }; inner() }
  outer()
  val seen: Int = read()
  assertEqualInt(x, 12, "x after the nested lambda's by-ref call")
  assertEqualInt(seen, 12, "sibling closure after the nested call")
}

test "lambda-local var captured by a nested closure, passed by ref in the lambda" {
  val h = { -> var y = 1; val r = { -> y }; setTo(y, 4); val seen: Int = r(); y * 10 + seen }
  val got: Int = h()
  assertEqualInt(got, 44, "lambda-local captured var after by-ref call")
}

test "captured Long" {
  var n: Long = 1i64
  val f = { -> n }
  setLong(n, 5000000000i64)
  val seen: Long = f()
  assertEqualLong(n, 5000000000i64, "n after setLong")
  assertEqualLong(seen, 5000000000i64, "f() after setLong")
}

test "captured String" {
  var s = "ab"
  val f = { -> s }
  appendTo(s, "cd")
  val seen: String = f()
  assertEqual(s, "abcd", "s after appendTo")
  assertEqual(seen, "abcd", "f() after appendTo")
}

test "captured Bool" {
  var on = false
  val f = { -> on }
  flip(on)
  val seen: Bool = f()
  assertTrue(on, "on after flip")
  assertTrue(seen, "f() after flip")
}

test "captured vars passed to a generic callee" {
  var s = "a"
  var n = 1
  val f = { -> s + toString(n) }
  assignAny(s, "z")
  assignAny(n, 26)
  val seen: String = f()
  assertEqual(seen, "z26", "f() after the generic callee's writes")
  assertEqual(s, "z", "s after assignAny")
  assertEqualInt(n, 26, "n after assignAny")
}

test "captured record var rebound by the callee" {
  var b = Box(n = 1)
  val f = { -> b.n }
  replaceBox(b, 21)
  val seen: Int = f()
  assertEqualInt(b.n, 21, "b.n after replaceBox")
  assertEqualInt(seen, 21, "f() after replaceBox")
}

test "captured var passed by ref after a `?` argument" {
  match propagateCase() {
    case Ok(v) -> assertEqualInt(v, 606, "x and f() after setFrom(okInt(6)?, x)")
    case Err(e) -> assertTrue(false, "unexpected Err: " + e)
  }
}

test "captured record: a closure's write during the call is kept (#8199)" {
  var b = Box(n = 1)
  val w = { -> b = Box(n = 5) }
  touchBox(b, w)
  assertEqualInt(b.n, 5, "b.n after the closure rebinds it during the call")
}

test "captured record: the closure sees the callee's write during the call (#8199)" {
  var b = Box(n = 1)
  val f = { -> b.n }
  val seen: Int = setBoxRead(b, f)
  assertEqualInt(seen, 9, "closure read inside the callee")
  assertEqualInt(b.n, 9, "b.n after the call")
}

test "captured String: the closure sees the callee's write during the call" {
  var s = "old"
  val f = { -> s }
  val seen: String = setStrRead(s, f)
  assertEqual(seen, "new", "closure read inside the callee")
  assertEqual(s, "new", "s after the call")
}

test "captured union var aliases the callee's parameter" {
  var s: Shape = Circle(r = 1)
  val w = { -> s = Circle(r = 2) }
  touchShape(s, w)
  assertEqualInt(area(s), 2, "closure write during the call")
  val f = { -> area(s) }
  val seen: Int = setShapeRead(s, f)
  assertEqualInt(seen, 300, "closure read inside the callee")
}

test "captured Option var aliases the callee's parameter" {
  var o: Option[Int] = None
  val w = { -> o = Some(5) }
  touchOpt(o, w)
  assertEqualInt(optVal(o), 5, "closure write during the call")
  val f = { -> optVal(o) }
  val seen: Int = setOptRead(o, f)
  assertEqualInt(seen, 8, "closure read inside the callee")
}

test "captured Result var aliases the callee's parameter" {
  var r: Result[Int, String] = Err("x")
  val w = { -> r = Ok(3) }
  touchRes(r, w)
  assertEqualInt(resVal(r), 3, "closure write during the call")
  val f = { -> resVal(r) }
  val seen: Int = setResRead(r, f)
  assertEqualInt(seen, 4, "closure read inside the callee")
}

test "captured generic record var aliases the callee's parameter" {
  var g = Gen(v = 1)
  val w = { -> g = Gen(v = 2) }
  touchGen(g, w)
  assertEqualInt(g.v, 2, "closure write during the call")
  val f = { -> g.v }
  val seen: Int = setGenRead(g, f)
  assertEqualInt(seen, 6, "closure read inside the callee")
}

test "captured List var aliases the callee's parameter" {
  var xs: List[Int] = newList()
  touchList(xs, { -> xs.add(4) })
  assertEqualInt(xs.count, 1, "closure write during the call")
  val f = { -> xs.count }
  val seen: Int = setListRead(xs, f)
  assertEqualInt(seen, 3, "closure read inside the callee")
}

test "captured slice var aliases the callee's parameter" {
  var sl: slice[Int] = [1]
  val w = { -> sl = [1, 2] }
  touchSlice(sl, w)
  assertEqualInt(sl.length, 2, "closure write during the call")
  val f = { -> sl.length }
  val seen: Int = setSliceRead(sl, f)
  assertEqualInt(seen, 4, "closure read inside the callee")
}

test "captured var passed to a generic record's `inout T` method (#8182)" {
  val h: Holder[Int] = Holder(tag = 0)
  var x = 1
  val f = { -> x }
  h.put(x, 42)
  val seen: Int = f()
  assertEqualInt(x, 42, "x after put")
  assertEqualInt(seen, 42, "f() after put")
  var y = 1
  h.put(y, 7)
  assertEqualInt(y, 7, "uncaptured y after put")
  val hb: Holder[Box] = Holder(tag = 0)
  var b = Box(n = 1)
  val fb = { -> b.n }
  hb.put(b, Box(n = 5))
  val seenB: Int = fb()
  assertEqualInt(seenB, 5, "captured record after put")
}

test "captured record passed to an erased `inout Self` parameter (#8204)" {
  val s = Cell(n = 0)
  var c = Cell(n = 1)
  val w = { -> c = Cell(n = 5) }
  s.takeFrom(c, w)
  assertEqualInt(c.n, 5, "closure write during the call")
  var d = Cell(n = 1)
  val f = { -> d.n }
  s.giveTo(d)
  val seen: Int = f()
  assertEqualInt(d.n, 6, "callee write")
  assertEqualInt(seen, 6, "closure read after the callee write")
}

test "captured record passed to both an erased `inout Self` and a typed `inout`" {
  val s = Cell(n = 0)
  var c = Cell(n = 1)
  val f = { -> c.n }
  setCell(c, 3)
  val afterTyped: Int = f()
  assertEqualInt(afterTyped, 3, "after the typed call")
  val w = { -> c = Cell(n = 8) }
  s.takeFrom(c, w)
  val afterSelf: Int = f()
  assertEqualInt(afterSelf, 8, "closure write during the erased call")
}

test "captured record passed to an erased `inout Self` inside an async func" {
  val r: Int = await asyncSwap()
  assertEqualInt(r, 5, "closure write during the call, across awaits")
}

test "a same-named method with a typed `inout` keeps the typed cell's aliasing" {
  val o = Other(k = 0)
  var c = Cell(n = 1)
  val w = { -> c = Cell(n = 5) }
  o.takeFrom(c, w)
  assertEqualInt(c.n, 5, "closure write during the typed call")
}
