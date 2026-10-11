//! hoisted_literal_shape_self_test.l — a literal whose runtime shape the
//! expected type decides keeps that shape when it is bound to a temporary
//! (#8190), on every target.
//!
//! A bracket literal is built as an `array[N, T]`, a `List[T]` or a `slice[T]`
//! of the expected element type according to the position it is written in,
//! not from its elements alone (D167, docs/01 §4.1). When an argument after it
//! holds a `?` or an `await`, the hoist (`Lyric.HoistEngine`) or the D171
//! argument-order rewrite binds the literal to a fresh local so it still runs
//! first; that local must be built as the parameter expects, or the callee
//! reads an array as a list (InvalidCastException on dotnet, N0007 on native).
//! The cases cover array, list and widened-slice literals before a `?` and
//! before an `await`, named arguments in and out of order with and without a
//! `?`, a by-reference variable and array element beside them (D171, D179), a
//! method call, a record's and a union case's fields, a generic callee, nested
//! literals, a tuple holding one, an `if` and a `match` whose value is one,
//! and the failing-`?` path.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/hoisted_literal_shape_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/hoisted_literal_shape_self_test.l
//!   lyric test --target native lyric-compiler/lyric/hoisted_literal_shape_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.HoistedLiteralShapeSelfTest

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

func ok(v: in Int): Result[Int, String] {
  trace.add("ok")
  Ok(value = v)
}

func fail(msg: in String): Result[Int, String] {
  trace.add("fail")
  Err(error = msg)
}

async func later(v: in Int): Int {
  trace.add("await")
  v
}

func sum3(xs: in array[2, Int], v: in Int): Int {
  xs[0] * 10 + xs[1] + v * 100
}

func sumList(xs: in List[Int], v: in Int): Int {
  var acc = v * 100
  for x in xs {
    acc = acc + x
  }
  acc
}

func sumWide(xs: in slice[Long], v: in Int): Long {
  var acc = v.toLong() * 100
  for x in xs {
    acc = acc + x
  }
  acc
}

func sumWideArray(xs: in array[2, Long], v: in Int): Long {
  xs[0] * 10 + xs[1] + v.toLong() * 100
}

func sumNamed(v: in Int, xs: in array[2, Int]): Int {
  xs[0] * 10 + xs[1] + v * 100
}

func sumGrid(g: in array[2, array[2, Int]], v: in Int): Int {
  g[0][0] * 1000 + g[0][1] * 100 + g[1][0] * 10 + g[1][1] + v * 10000
}

func sumRows(rows: in List[array[2, Int]], v: in Int): Int {
  var acc = v * 1000
  for r in rows {
    acc = acc + r[0] * 10 + r[1]
  }
  acc
}

func sumPair(p: in (array[2, Int], Int), v: in Int): Int {
  val (xs, n) = p
  xs[0] * 10 + xs[1] + n * 100 + v * 1000
}

func firstOf[T](xs: in array[2, T], v: in Int): T {
  xs[v]
}

func addInto(acc: inout Int, xs: in array[2, Int], v: in Int): Unit {
  acc = acc + xs[0] * 10 + xs[1] + v * 100
}

record Box {
  xs: array[2, Int]
  n: Int
}

record Bag {
  items: List[Int]
  n: Int
}

union Holder {
  case Two(xs: array[2, Int], n: Int)
  case Nothing
}

record Scale {
  k: Int

  func apply(self: in Scale, xs: in array[2, Int], v: in Int): Int {
    (xs[0] * 10 + xs[1] + v * 100) * self.k
  }
}

func boxSum(b: in Box): Int {
  b.xs[0] * 10 + b.xs[1] + b.n * 100
}

func arrayBeforeTry(): Result[Int, String] {
  Ok(value = sum3([7, 8], ok(1)?))
}

func listBeforeTry(): Result[Int, String] {
  Ok(value = sumList([7, 8], ok(1)?))
}

// A tuple's elements are hoisted one by one, so the slice literal is bound
// ahead of the `?` beside it at the element type the annotation gives.
func wideBeforeTry(): Result[Long, String] {
  val p: (slice[Long], Int) = ([7, 8], ok(1)?)
  val (xs, v) = p
  Ok(value = sumWide(xs, v))
}

// Each element widens to the parameter's element type, as it does when the
// literal is passed directly.
func wideArrayBeforeTry(): Result[Long, String] {
  Ok(value = sumWideArray([7, 8], ok(1)?))
}

func parenArrayBeforeTry(): Result[Int, String] {
  Ok(value = sum3(([7, 8]), ok(1)?))
}

func namedInOrder(): Result[Int, String] {
  Ok(value = sumNamed(v = ok(1)?, xs = [7, 8]))
}

func namedOutOfOrder(): Result[Int, String] {
  Ok(value = sumNamed(xs = [note("xs", 7), 8], v = ok(1)?))
}

func byRefBeside(acc: inout Int): Result[Unit, String] {
  addInto(acc, [note("xs", 7), 8], ok(1)?)
  Ok(value = ())
}

func methodBeforeTry(s: in Scale): Result[Int, String] {
  Ok(value = s.apply([7, 8], ok(1)?))
}

func ctorFieldsBeforeTry(): Result[Int, String] {
  Ok(value = boxSum(Box(xs = [7, 8], n = ok(1)?)))
}

func ctorListFieldBeforeTry(): Result[Int, String] {
  val b = Bag(items = [7, 8], n = ok(1)?)
  Ok(value = sumList(b.items, b.n))
}

func holderSum(h: in Holder): Int {
  match h {
    case Two(xs, n) -> xs[0] * 10 + xs[1] + n * 100
    case Nothing -> 0
  }
}

func unionCaseBeforeTry(): Result[Int, String] {
  Ok(value = holderSum(Two(xs = [7, 8], n = ok(1)?)))
}

func ctorNamedOutOfOrder(): Result[Int, String] {
  Ok(value = boxSum(Box(n = ok(1)?, xs = [7, 8])))
}

func genericBeforeTry(): Result[Int, String] {
  Ok(value = firstOf([7, 8], ok(1)?))
}

func genericStringBeforeTry(): Result[String, String] {
  Ok(value = firstOf(["a", "b"], ok(0)?))
}

func nestedBeforeTry(): Result[Int, String] {
  Ok(value = sumGrid([[1, 2], [3, 4]], ok(5)?))
}

func listOfArraysBeforeTry(): Result[Int, String] {
  val rows: List[array[2, Int]] = [[1, 2], [ok(3)?, 4]]
  Ok(value = sumRows(rows, 5))
}

func tupleBeforeTry(): Result[Int, String] {
  val p: ((array[2, Int], Int), Int) = (([7, 8], 9), ok(1)?)
  val (inner, v) = p
  Ok(value = sumPair(inner, v))
}

func ifBeforeTry(c: in Bool): Result[Int, String] {
  Ok(value = sum3(if c { [7, 8] } else { [1, 2] }, ok(1)?))
}

func matchBeforeTry(n: in Int): Result[Int, String] {
  Ok(value = sum3(match n { case 0 -> [7, 8]; case _ -> [1, 2] }, ok(1)?))
}

func namedNoHazard(): Int {
  sumNamed(xs = [note("xs", 7), 8], v = note("v", 1))
}

func elementPlaceBeside(cells: inout array[2, Int]): Result[Unit, String] {
  addInto(cells[note("i", 1)], [note("xs", 7), 8], ok(1)?)
  Ok(value = ())
}

func arrayBeforeFailingTry(): Result[Int, String] {
  Ok(value = sum3([note("xs", 7), 8], fail("no")?))
}

async func arrayBeforeAwait(): Int {
  sum3([7, 8], await later(1))
}

async func listBeforeAwait(): Int {
  sumList([7, 8], await later(1))
}

async func wideBeforeAwait(): Long {
  val p: (slice[Long], Int) = ([7, 8], await later(1))
  val (xs, v) = p
  sumWide(xs, v)
}

async func namedBeforeAwait(): Int {
  sumNamed(xs = [note("xs", 7), 8], v = await later(1))
}

async func ctorBeforeAwait(): Int {
  boxSum(Box(xs = [7, 8], n = await later(1)))
}

async func nestedBeforeAwait(): Int {
  sumGrid([[1, 2], [3, 4]], await later(5))
}

async func tupleBeforeAwait(): Int {
  val p: ((array[2, Int], Int), Int) = (([7, 8], 9), await later(1))
  val (inner, v) = p
  sumPair(inner, v)
}

async func listOfArraysBeforeAwait(): Int {
  val rows: List[array[2, Int]] = [[1, 2], [await later(3), 4]]
  sumRows(rows, 5)
}

async func methodBeforeAwait(s: in Scale): Int {
  s.apply([7, 8], await later(1))
}

async func genericBeforeAwait(): Int {
  firstOf([7, 8], await later(1))
}

func expectOk(r: in Result[Int, String], want: in Int, label: in String): Unit {
  match r {
    case Ok(v) -> assertEqualInt(v, want, label)
    case Err(e) -> assertTrue(false, label + ": unexpected Err " + e)
  }
}

test "an array literal before a ? argument, the issue's repro" {
  expectOk(arrayBeforeTry(), 178, "sum3")
  expectOk(parenArrayBeforeTry(), 178, "parenthesised")
}

test "list and widened slice literals before a ? argument" {
  expectOk(listBeforeTry(), 115, "List")
  match wideBeforeTry() {
    case Ok(v) -> assertTrue(v == 115i64, "slice[Long]")
    case Err(e) -> assertTrue(false, "slice[Long]: " + e)
  }
  match wideArrayBeforeTry() {
    case Ok(v) -> assertTrue(v == 178i64, "array[2, Long]")
    case Err(e) -> assertTrue(false, "array[2, Long]: " + e)
  }
}

test "named arguments in and out of order, in source order" {
  expectOk(namedInOrder(), 178, "in order")
  val start = trace.count
  expectOk(namedOutOfOrder(), 178, "out of order")
  assertEqual(since(start), "xs,ok", "source order")
}

test "a by-reference place beside an array literal and a ?" {
  var acc = 1000
  val start = trace.count
  match byRefBeside(acc) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, e)
  }
  assertEqualInt(acc, 1178, "written through")
  assertEqual(since(start), "xs,ok", "source order")
}

test "a method call's array argument before a ?" {
  expectOk(methodBeforeTry(Scale(k = 2)), 356, "method")
}

test "constructor fields holding literals before a ?" {
  expectOk(ctorFieldsBeforeTry(), 178, "array field")
  expectOk(ctorListFieldBeforeTry(), 115, "List field")
  expectOk(ctorNamedOutOfOrder(), 178, "named out of order")
  expectOk(unionCaseBeforeTry(), 178, "union case field")
}

test "a generic callee whose parameter is array[2, T]" {
  expectOk(genericBeforeTry(), 8, "Int")
  match genericStringBeforeTry() {
    case Ok(v) -> assertEqual(v, "a", "String")
    case Err(e) -> assertTrue(false, "String: " + e)
  }
}

test "nested literals and a tuple holding one before a ?" {
  expectOk(nestedBeforeTry(), 51234, "array of arrays")
  expectOk(listOfArraysBeforeTry(), 5046, "List of arrays")
  expectOk(tupleBeforeTry(), 1978, "tuple")
}

test "an if or match whose value is an array literal before a ?" {
  expectOk(ifBeforeTry(true), 178, "if then")
  expectOk(ifBeforeTry(false), 112, "if else")
  expectOk(matchBeforeTry(0), 178, "match first arm")
  expectOk(matchBeforeTry(3), 112, "match other arm")
}

test "named arguments out of order with no ? or await" {
  val start = trace.count
  assertEqualInt(namedNoHazard(), 178, "value")
  assertEqual(since(start), "xs,v", "source order")
}

test "an array element passed by reference beside a literal and a ?" {
  var cells: array[2, Int] = [0, 1000]
  val start = trace.count
  match elementPlaceBeside(cells) {
    case Ok(_) -> ()
    case Err(e) -> assertTrue(false, e)
  }
  assertEqualInt(cells[1], 1178, "written through")
  assertEqualInt(cells[0], 0, "other element")
  assertEqual(since(start), "i,xs,ok", "source order")
}

test "the literal runs before a failing ? and the call does not" {
  val start = trace.count
  match arrayBeforeFailingTry() {
    case Ok(v) -> assertTrue(false, "unexpected Ok " + toString(v))
    case Err(e) -> assertEqual(e, "no", "error")
  }
  assertEqual(since(start), "xs,fail", "order")
}

test "literals before an await argument" {
  assertEqualInt(await arrayBeforeAwait(), 178, "array")
  assertEqualInt(await listBeforeAwait(), 115, "List")
  assertTrue(await wideBeforeAwait() == 115i64, "slice[Long]")
  val start = trace.count
  assertEqualInt(await namedBeforeAwait(), 178, "named")
  assertEqual(since(start), "xs,await", "source order")
  assertEqualInt(await ctorBeforeAwait(), 178, "constructor")
  assertEqualInt(await nestedBeforeAwait(), 51234, "nested")
  assertEqualInt(await tupleBeforeAwait(), 1978, "tuple")
  assertEqualInt(await listOfArraysBeforeAwait(), 5046, "List of arrays")
  assertEqualInt(await methodBeforeAwait(Scale(k = 2)), 356, "method")
  assertEqualInt(await genericBeforeAwait(), 8, "generic")
}
