//! inout_array_element_self_test.l — runtime regression test for an element
//! of an `array[N, T]` passed to an `out`/`inout` parameter (#8180), on every
//! target.
//!
//! An array element is a place (docs/01 §2.7), so it may be passed by
//! reference, or be the receiver of a method whose receiver is
//! `self: inout`.  Such a call type-checked but failed in codegen on every
//! backend.  The middle end now copies the element into a temporary the call
//! writes and stores it back into the element after the call
//! (`Lyric.Mono.argOrderCallMono`): the array is never copied, each computed
//! index runs once, in source order (D171), and the copy is made after every
//! argument has run, as the JVM fills the holder of any `out`/`inout` place.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/inout_array_element_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/inout_array_element_self_test.l
//!   lyric test --target native lyric-compiler/lyric/inout_array_element_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.InoutArrayElementSelfTest

import Std.Core
import Std.Collections
import Std.Testing

val trace: List[String] = newList()

func note(s: in String, v: in Int): Int {
  trace.add(s)
  v
}

func noteOk(s: in String, v: in Int): Result[Int, String] {
  trace.add(s)
  Ok(value = v)
}

func noteErr(s: in String): Result[Int, String] {
  trace.add(s)
  Err(error = "failed at " + s)
}

async func noteAsync(s: in String, v: in Int): Int {
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

func setTo(x: inout Int, v: in Int): Unit {
  x = v
}

func putOut(x: out Int, v: in Int): Unit {
  x = v
}

func addBoth(x: inout Int, a: in Int, b: in Int): Unit {
  x = x + a * 10 + b
}

// Returns the old value and stores `v`.
func swapIn(x: inout Int, v: in Int): Int {
  val prev = x
  x = v
  prev
}

func swapPair(a: inout Int, b: inout Int): Unit {
  val t = a
  a = b
  b = t
}

func fillRow(r: inout array[2, Int], v: in Int): Unit {
  r[0] = v
  r[1] = v + 1
}

func appendTo(s: inout String, tail: in String): Unit {
  s = s + tail
}

func setGeneric[T](x: inout T, v: in T): Unit {
  x = v
}

// A value record: replaced, never mutated (D157).
record Pt {
  x: Int
  y: Int

  func reset(self: inout Pt): Unit {
    self = Pt(x = 0, y = 0)
  }

  func moved(self: inout Pt, d: in Int): Unit {
    self = Pt(x = x + d, y = y + d)
  }
}

func Pt.scaled(self: inout Pt, k: in Int): Unit {
  self = Pt(x = self.x * k, y = self.y * k)
}

// A record with identity, whose fields are written in place.
record Cell {
  var v: Int
}

record Counter {
  var n: Int

  func next(self: inout Counter): Int {
    val prev = n
    self = Counter(n = n + 1)
    prev
  }
}

record Grid {
  var rows: array[2, array[3, Int]]
  var cells: array[2, Cell]
  var nums: array[3, Int]
}

func sumOf(a: in array[3, Int]): Int {
  a[0] + a[1] + a[2]
}

func at(s: in String, i: in Int): Int {
  trace.add(s)
  i
}

test "an inout element is written in place" {
  var a: array[3, Int] = [1, 2, 3]
  setTo(a[1], 9)
  assertEqualInt(a[0], 1, "a[0] untouched")
  assertEqualInt(a[1], 9, "a[1] written")
  assertEqualInt(a[2], 3, "a[2] untouched")
  var i = 2
  setTo(a[i], 7)
  assertEqualInt(a[2], 7, "a computed index")
  addBoth(a[0], 2, 3)
  assertEqualInt(a[0], 24, "read and written")
}

test "an out element is written" {
  var a: array[3, Int] = [1, 2, 3]
  putOut(a[2], 40)
  assertEqualInt(sumOf(a), 43, "a[2] written")
}

test "two elements of one array passed by reference are both written" {
  var a: array[3, Int] = [1, 2, 3]
  swapPair(a[0], a[2])
  assertEqualInt(a[0], 3, "a[0] took a[2]")
  assertEqualInt(a[2], 1, "a[2] took a[0]")
}

test "a call's value is kept across the store back" {
  var a: array[3, Int] = [1, 2, 3]
  val got = swapIn(a[1], 20) + 100
  assertEqualInt(got, 102, "the old value is returned")
  assertEqualInt(a[1], 20, "the new value is stored")
  assertEqualInt(swapIn(a[2], 30) * swapIn(a[2], 4), 90, "two calls in one expression")
  assertEqualInt(a[2], 4, "the later call wins")
}

test "a computed index runs once, in source order" {
  var a: array[3, Int] = [0, 0, 0]
  val t0 = trace.count
  addBoth(a[at("i", 1)], note("a", 2), note("b", 3))
  assertEqualInt(a[1], 23, "the element was updated")
  assertEqualInt(sumOf(a), 23, "no other element was written")
  assertEqual(since(t0), "i,a,b", "the index runs at its turn")
  val t1 = trace.count
  addBoth(b = note("b", 4), x = a[at("i", 2)], a = note("a", 5))
  assertEqualInt(a[2], 54, "named arguments")
  assertEqual(since(t1), "b,i,a", "source order, not parameter order")
}

test "an element's index is evaluated before the arguments that follow it" {
  var a: array[3, Int] = [10, 20, 30]
  var k = 0
  setTo(a[k], swapIn(k, 2))
  assertEqualInt(a[0], 0, "the element at the old index was written")
  assertEqualInt(a[2], 30, "the element at the new index was not")
  assertEqualInt(k, 2, "the index variable was written by the later argument")
}

func elemBeforePropagate(a: inout array[3, Int]): Result[Int, String] {
  setTo(a[at("i", 2)], noteOk("v", 7)?)
  Ok(value = a[2])
}

func elemBetweenPropagates(a: inout array[3, Int]): Result[Int, String] {
  addBoth(a[at("i", 0)], note("a", 2), noteOk("b", 3)?)
  Ok(value = a[0])
}

func elemBeforeFailure(a: inout array[3, Int]): Result[Int, String] {
  setTo(a[at("i", 1)], noteErr("e")?)
  Ok(value = a[1])
}

test "an element beside a ? argument is written, and its index runs first" {
  var a: array[3, Int] = [1, 2, 3]
  val t0 = trace.count
  match elemBeforePropagate(a) {
    case Ok(v) -> assertEqualInt(v, 7, "the element was written")
    case Err(e) -> assertTrue(false, "unexpected error " + e)
  }
  assertEqual(since(t0), "i,v", "order")
  assertEqualInt(a[2], 7, "the caller's array was written through the inout parameter")
  val t1 = trace.count
  match elemBetweenPropagates(a) {
    case Ok(v) -> assertEqualInt(v, 24, "read and written")
    case Err(e) -> assertTrue(false, "unexpected error " + e)
  }
  assertEqual(since(t1), "i,a,b", "order")
  val t2 = trace.count
  match elemBeforeFailure(a) {
    case Ok(_) -> assertTrue(false, "the ? should have failed")
    case Err(e) -> assertEqual(e, "failed at e", "the error propagates")
  }
  assertEqual(since(t2), "i,e", "the index runs before the failing argument")
  assertEqualInt(a[1], 2, "no call, no store")
}

func setChecked(x: inout Int, v: in Int): Result[Int, String] {
  if v < 0 {
    return Err(error = "negative")
  }
  x = v
  Ok(value = v * 2)
}

func propagateResult(a: inout array[2, Int], v: in Int): Result[Int, String] {
  val d = setChecked(a[1], v)?
  Ok(value = d + 1)
}

func returnsCall(a: inout array[2, Int]): Int {
  return swapIn(a[0], 2) + 40
}

func fail(x: inout Int): Never {
  x = 1
  panic("fail")
}

func maybeFail(a: inout array[2, Int], flag: in Bool): Int {
  if flag {
    fail(a[0])
  }
  a[0]
}

test "the call's own result: propagated with ?, returned, or Never" {
  var a: array[2, Int] = [0, 0]
  match propagateResult(a, 5) {
    case Ok(v) -> assertEqualInt(v, 11, "the call's value")
    case Err(e) -> assertTrue(false, "unexpected error " + e)
  }
  assertEqualInt(a[1], 5, "the element was written")
  match propagateResult(a, -1) {
    case Ok(_) -> assertTrue(false, "the ? should have failed")
    case Err(e) -> assertEqual(e, "negative", "the error propagates")
  }
  assertEqualInt(a[1], 5, "a call that did not write stores the value it read")
  assertEqualInt(returnsCall(a), 40, "returned")
  assertEqualInt(a[0], 2, "the element was written")
  assertEqualInt(maybeFail(a, false), 2, "a Never call that does not run")
}

async func elemBeforeAwait(): Int {
  var a: array[2, Int] = [1, 1]
  setTo(a[at("i", 1)], await noteAsync("v", 8))
  addBoth(a[0], note("a", 2), await noteAsync("b", 3))
  a[0] * 100 + a[1]
}

test "an element beside an await argument is written" {
  val t0 = trace.count
  assertEqualInt(await elemBeforeAwait(), 2408, "both elements were written")
  assertEqual(since(t0), "i,v,a,b", "order")
}

test "an element of an array field, and a field of an element" {
  var g = Grid(rows = [[1, 2, 3], [4, 5, 6]], cells = [Cell(v = 1), Cell(v = 2)], nums = [7, 8, 9])
  setTo(g.nums[1], 80)
  assertEqualInt(g.nums[1], 80, "an element of a field")
  setTo(g.cells[1].v, 22)
  assertEqualInt(g.cells[1].v, 22, "a field of an element of a field")
  var cells: array[2, Cell] = [Cell(v = 1), Cell(v = 2)]
  var j = 0
  addBoth(cells[j].v, 1, 2)
  assertEqualInt(cells[0].v, 13, "a field of an element")
}

test "an element of an element, and an array element passed as an array" {
  var m: array[2, array[3, Int]] = [[1, 2, 3], [4, 5, 6]]
  setTo(m[1][2], 60)
  assertEqualInt(m[1][2], 60, "m[1][2] written")
  assertEqualInt(m[0][2], 3, "m[0][2] untouched")
  var g = Grid(rows = [[1, 2, 3], [4, 5, 6]], cells = [Cell(v = 1), Cell(v = 2)], nums = [7, 8, 9])
  var r = 0
  setTo(g.rows[r][1], 50)
  assertEqualInt(g.rows[0][1], 50, "an element of an element of a field")
  var rows: array[2, array[2, Int]] = [[0, 0], [0, 0]]
  fillRow(rows[1], 5)
  assertEqualInt(rows[1][0], 5, "the row was written")
  assertEqualInt(rows[1][1], 6, "the whole row")
  assertEqualInt(rows[0][0], 0, "the other row untouched")
}

test "an array that is copied keeps its own elements" {
  var a: array[3, Int] = [1, 2, 3]
  val before = a
  setTo(a[0], 100)
  assertEqualInt(a[0], 100, "the variable's array was written")
  assertEqualInt(before[0], 1, "an earlier copy was not")
}

test "an element is an inout receiver" {
  var pts: array[3, Pt] = [Pt(x = 1, y = 2), Pt(x = 3, y = 4), Pt(x = 5, y = 6)]
  pts[1].reset()
  assertEqualInt(pts[1].x + pts[1].y, 0, "pts[1] reset")
  assertEqualInt(pts[0].x, 1, "pts[0] untouched")
  var i = 2
  pts[i].moved(10)
  assertEqualInt(pts[2].x, 15, "a computed index")
  Pt.scaled(pts[0], 3)
  assertEqualInt(pts[0].y, 6, "through the type name")
  var ctrs: array[2, Counter] = [Counter(n = 5), Counter(n = 7)]
  val first = ctrs[1].next()
  assertEqualInt(first, 7, "the method's value")
  assertEqualInt(ctrs[1].n, 8, "the receiver was replaced")
  val t0 = trace.count
  pts[at("i", 0)].moved(note("d", 1))
  assertEqual(since(t0), "i,d", "the receiver's index runs first")
  assertEqualInt(pts[0].x, 4, "moved")
}

test "an element of an inout array parameter" {
  var a: array[3, Int] = [1, 2, 3]
  bumpAll(a)
  assertEqualInt(sumOf(a), 36, "every element was written through the parameter")
}

func bumpAll(a: inout array[3, Int]): Unit {
  var i = 0
  while i < 3 {
    addBoth(a[i], 1, 0)
    i = i + 1
  }
}

// An element of an array a closure captures is covered, on dotnet and the
// JVM, by `closure_captured_var_byref_self_test.l`: `--target native` still
// captures a `var` by value (#7891 item 1).
test "an element passed by reference inside a lambda" {
  val f = { v: Int -> var loc: array[2, Int] = [0, 0]; setTo(loc[1], v); loc[0] * 10 + loc[1] }
  val got: Int = f(7)
  assertEqualInt(got, 7, "the lambda's own array was written")
}

test "an element of a reference type and of a generic parameter" {
  var names: array[2, String] = ["a", "b"]
  appendTo(names[1], "cd")
  assertEqual(names[1], "bcd", "a String element")
  var a: array[2, Int] = [1, 2]
  setGeneric(a[0], 9)
  assertEqualInt(a[0], 9, "an element passed at a type parameter")
  var opts: array[2, Option[Int]] = [None, Some(value = 1)]
  setGeneric(opts[0], Some(value = 5))
  match opts[0] {
    case Some(v) -> assertEqualInt(v, 5, "an Option element")
    case None -> assertTrue(false, "the element was not written")
  }
}

test "an element with a Long index" {
  var a: array[3, Int] = [1, 2, 3]
  val i: Long = 2
  setTo(a[i], 11)
  assertEqualInt(a[2], 11, "a Long index")
}
