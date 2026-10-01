//! expected_type_propagation_self_test.l — dual-target runtime regression
//! test for positions that lost the type a construction is built at on
//! --target dotnet (#7855, #7863).
//!
//! 1. An unannotated tuple local: `val t = (None, 5)`, where only a later use
//!    fixes the `None`'s type argument, built an `Option<object>`.  An
//!    unannotated `Ok(2)` or `Err("e")` local lost its other argument the same
//!    way.  The open-binding inference (#7788) now covers them: a tuple
//!    literal's open elements are typed from the uses of the tuple, and of the
//!    names a tuple pattern binds from it.
//! 2. The value of a field or element assignment:
//!    `cell.o = if c { None } else { Some(5) }` built its `None` arm at
//!    `object` ("match not exhaustive").  MSIL now lowers the value with the
//!    target's type as its construction context, as it does a `val`
//!    initialiser.
//!
//! 3. Three shapes #7855 left open (#7863): a name bound to a nested
//!    sub-tuple (`val (inner, n) = ((None, 1), 2)`, then a use of `inner`),
//!    an element fixed through a generic function's own type parameter and
//!    read through a pattern-bound name (J008 on the JVM), and a tuple
//!    literal matched directly (`match (None, 5) { ... }`).  Wider tuples
//!    with open elements apart are covered too.
//!
//! Each shape is exercised synchronously and in an `async func` whose await
//! hoist binds the operands (#7823).  --target jvm erases generics, so only a
//! name read from an erased tuple element failed there (J008); it runs every
//! case too.
//!
//! Run via `lyric test`:
//!
//!   lyric test --target dotnet lyric-compiler/lyric/expected_type_propagation_self_test.l
//!   lyric test --target jvm lyric-compiler/lyric/expected_type_propagation_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.ExpectedTypePropagationSelfTest

import Std.Core
import Std.Collections
import Std.Task
import Std.Testing

async func five(): Int {
  await Std.Task.delay(5)
  5
}

func optValue(a: in Option[Int]): Int {
  match a {
    case Some(v) -> v
    case None -> 1000
  }
}

func resValue(a: in Result[Int, String]): Int {
  match a {
    case Ok(v) -> v
    case Err(e) -> e.length * 100
  }
}

func addOpt(a: in Option[Int], b: in Int): Int {
  optValue(a) + b
}

func sumList(xs: in List[Int]): Int {
  var t = 0
  for x in xs {
    t = t + x
  }
  t
}

func pairValue(p: in (Option[Int], Int)): Int {
  val (o, n) = p
  optValue(o) + n
}

func resPairValue(p: in (Result[Int, String], Result[Int, String])): Int {
  val (a, b) = p
  resValue(a) + resValue(b)
}

func nestedValue(p: in ((Option[Int], Int), Int)): Int {
  val (inner, n) = p
  pairValue(inner) + n
}

func listPairValue(p: in (List[Int], Int)): Int {
  val (xs, n) = p
  sumList(xs) + n
}

record OptCell {
  var o: Option[Int]

  func setFrom(self: in OptCell, c: in Bool): Unit {
    self.o = if c { None } else { Some(5) }
  }
}

record ResCell {
  var r: Result[Int, String]
}

record ListCell {
  var xs: List[Int]
}

record Outer {
  cell: OptCell
}

record Holder[T] {
  var value: Option[T]
}

record LongCell {
  var n: Long
}

// ── 1. Unannotated tuple and Ok/Err locals ───────────────────────────────────
func tupleArgument(): Int {
  val t = (None, 5)
  pairValue(t)
}

func tupleReturned(): (Option[Int], Int) {
  val t = (None, 5)
  t
}

func tupleDestructured(): Int {
  val t = (None, 5)
  val (o, n) = t
  addOpt(o, n)
}

func literalDestructured(): Int {
  val (o, n) = (None, 5)
  addOpt(o, n)
}

func tupleMatched(): Int {
  val t = (None, 5)
  match t {
    case (o, n) -> addOpt(o, n)
  }
}

func tupleNested(): Int {
  val t = ((None, 1), 2)
  nestedValue(t)
}

func tupleOkErr(): Int {
  val t = (Ok(2), Err("abc"))
  resPairValue(t)
}

func tupleNewListStores(): Int {
  val t = (newList(), 3)
  val (xs, n) = t
  xs.add(n)
  xs.add(4)
  xs.count * 100 + xs[0] + xs[1]
}

func tupleHoldsOpenLocal(): Int {
  val xs = newList()
  val t = (xs, 1)
  xs.add(6)
  listPairValue(t)
}

func tupleReassigned(c: in Bool): Int {
  var t = (None, 5)
  if c {
    t = (Some(3), 4)
  }
  pairValue(t)
}

func okLocal(): Int {
  val r = Ok(2)
  resValue(r)
}

func errLocal(): Int {
  val r = Err("abc")
  resValue(r)
}

// ── 2. if/match values assigned to a field or an element ─────────────────────
func fieldIf(c: in Bool): Int {
  val cell = OptCell(o = Some(1))
  cell.o = if c { None } else { Some(5) }
  optValue(cell.o)
}

func fieldMatch(k: in Int): Int {
  val cell = OptCell(o = Some(1))
  cell.o = match k { case 0 -> None; case _ -> Some(5) }
  optValue(cell.o)
}

func fieldNone(): Int {
  val cell = OptCell(o = Some(1))
  cell.o = None
  optValue(cell.o)
}

func fieldBlock(c: in Bool): Int {
  val cell = OptCell(o = Some(1))
  cell.o = if c { val k = 0; if k == 0 { None } else { Some(k) } } else { Some(5) }
  optValue(cell.o)
}

func fieldOkErr(c: in Bool): Int {
  val cell = ResCell(r = Ok(1))
  cell.r = if c { Ok(7) } else { Err("ab") }
  resValue(cell.r)
}

func fieldNewList(c: in Bool): Int {
  val cell = ListCell(xs = newList())
  cell.xs.add(9)
  cell.xs = if c { newList() } else { cell.xs }
  cell.xs.add(1)
  sumList(cell.xs)
}

func nestedField(c: in Bool): Int {
  val outer = Outer(cell = OptCell(o = Some(1)))
  outer.cell.o = if c { None } else { Some(5) }
  optValue(outer.cell.o)
}

func selfField(c: in Bool): Int {
  val cell = OptCell(o = Some(1))
  cell.setFrom(c)
  optValue(cell.o)
}

func genericField(c: in Bool): Int {
  val h: Holder[Int] = Holder(value = Some(1))
  h.value = if c { None } else { Some(5) }
  optValue(h.value)
}

func listElement(c: in Bool): Int {
  val xs: List[Option[Int]] = newList()
  xs.add(Some(1))
  xs[0] = if c { None } else { Some(5) }
  optValue(xs[0])
}

func mapValue(c: in Bool): Int {
  val m: Map[String, Result[Int, String]] = newMap()
  m["k"] = if c { Ok(7) } else { Err("abc") }
  resValue(m["k"])
}

func sliceElement(c: in Bool): Int {
  val xs: slice[Option[Int]] = [Some(1), Some(2)]
  xs[1] = match c { case true -> None; case false -> Some(5) }
  optValue(xs[1])
}

func compoundField(c: in Bool): Long {
  val cell = LongCell(n = 10i64)
  cell.n += if c { 1 } else { 2 }
  cell.n
}

// ── Awaiting variants ─────────────────────────────────────────────────────────
async func asyncTuple(): Int {
  val t = (None, await five())
  pairValue(t)
}

async func asyncTupleDestructured(): Int {
  val (o, n) = (None, await five())
  addOpt(o, n)
}

async func asyncTupleOkErr(): Int {
  val t = (Err("abc"), Ok(await five()))
  resPairValue(t)
}

async func asyncTupleAfter(): Int {
  val t = (None, 5)
  val k = await five()
  pairValue(t) + k
}

async func asyncOkLocal(): Int {
  val r = Err("ab")
  resValue(r) + await five()
}

async func asyncFieldIf(c: in Bool): Int {
  val cell = OptCell(o = Some(1))
  cell.o = if c { None } else { Some(5) }
  optValue(cell.o) + await five()
}

async func asyncFieldMatchAwait(k: in Int): Int {
  val cell = ResCell(r = Ok(1))
  cell.r = match k { case 0 -> Err("abc"); case _ -> Ok(await five()) }
  resValue(cell.r)
}

async func asyncElementAwait(c: in Bool): Int {
  val xs: List[Option[Int]] = newList()
  xs.add(Some(1))
  xs[0] = if c { None } else { Some(await five()) }
  optValue(xs[0])
}

// ── 3. Names bound to a nested sub-tuple (#7863) ─────────────────────────────
func subTupleSink(): Int {
  val t = ((None, 1), 2)
  val (inner, n) = t
  pairValue(inner) + n
}

func subTupleLiteral(): Int {
  val (inner, n) = ((Ok(2), Err("abc")), 1)
  resPairValue(inner) + n
}

func subTupleStores(): Int {
  val t = ((newList(), 1), 2)
  val (inner, n) = t
  val (xs, k) = inner
  xs.add(k)
  xs.add(n)
  sumList(xs) + xs.count * 100
}

func subTupleMatched(): Int {
  val t = ((None, 1), 2)
  match t {
    case (inner, n) -> pairValue(inner) + n
  }
}

func subTupleDeep(): Int {
  val t = (((None, 1), 2), 3)
  val (mid, a) = t
  val (inner, b) = mid
  pairValue(inner) + a + b
}

func wholeTupleArm(): Int {
  val t = (None, 5)
  match t {
    case whole -> pairValue(whole)
  }
}

// ── 4. Type parameters reached through a pattern-bound name (#7863) ──────────
func listViaLocal[T](x: in T, y: in T): List[T] {
  val t = (newList(), 2)
  val (xs, n) = t
  xs.add(x)
  xs.add(y)
  xs
}

func listViaArm[T](x: in T): List[T] {
  val t = (newList(), 2)
  match t {
    case (xs, n) -> {
      xs.add(x)
      xs
    }
  }
}

func mapViaLocal[T](k: in String, x: in T): Map[String, T] {
  val t = (newMap(), 1)
  val (m, n) = t
  m.add(k, x)
  m
}

func optViaLocal[T](x: in T, c: in Bool): Option[T] {
  var t = (None, 1)
  if c {
    t = (Some(x), 2)
  }
  val (o, n) = t
  o
}

func resViaArm[T](x: in T, c: in Bool): Result[T, String] {
  var t = (Err("abc"), 1)
  if c {
    t = (Ok(x), 2)
  }
  match t {
    case (r, n) -> r
  }
}

func typedPairParam[T](p: in (List[T], Int), x: in T): Int {
  val (xs, n) = p
  xs.add(x)
  xs.count * 10 + n
}

// ── 5. A tuple literal matched directly (#7863) ──────────────────────────────
func scrutNone(): Int {
  match (None, 5) {
    case (Some(x), n) -> x + n
    case (o, n) -> addOpt(o, n)
  }
}

func scrutOkErr(): Int {
  match (Ok(2), Err("abc")) {
    case (a, b) -> resValue(a) + resValue(b)
  }
}

func scrutNewList(): Int {
  match (newList(), 3) {
    case (xs, n) -> {
      xs.add(n)
      xs.add(4)
      sumList(xs) + xs.count * 100
    }
  }
}

func scrutWhole(): Int {
  match (None, 5) {
    case p -> pairValue(p)
  }
}

func scrutGeneric[T](x: in T): List[T] {
  match (newList(), 1) {
    case (xs, n) -> {
      xs.add(x)
      xs
    }
  }
}

// The checker sees a matched literal through any depth of parentheses, so
// Mono must too.
func scrutDoubleParen(): Int {
  match ((None, 5)) {
    case (Some(x), n) -> x + n
    case (o, n) -> addOpt(o, n)
  }
}

func scrutTripleParen(): Int {
  match (((Ok(2), Err("abc")))) {
    case (a, b) -> resValue(a) + resValue(b)
  }
}

async func asyncScrut(): Int {
  match (None, await five()) {
    case (o, n) -> addOpt(o, n)
  }
}

// ── 6. Wider tuples, open elements apart ─────────────────────────────────────
func tripleValue(p: in (Option[Int], Int, Result[Int, String])): Int {
  val (o, n, r) = p
  optValue(o) + n + resValue(r)
}

func wideArgument(): Int {
  val t = (None, 3, Ok(1))
  tripleValue(t)
}

func wideDestructured(): Int {
  val (a, b, c) = (None, 3, Err("ab"))
  addOpt(a, b) + resValue(c)
}

func wideNested(): Int {
  val t = ((None, 1, Ok(4)), 2, newList())
  val (inner, n, xs) = t
  xs.add(n)
  tripleValue(inner) + sumList(xs)
}

func wideScrutinee(): Int {
  match (Ok(6), 1, None, newList()) {
    case (r, n, o, xs) -> {
      xs.add(n)
      resValue(r) + addOpt(o, n) + sumList(xs)
    }
  }
}

test "an unannotated tuple is typed from its uses" {
  assertEqualInt(tupleArgument(), 1005, "argument")
  assertEqualInt(pairValue(tupleReturned()), 1005, "returned")
  assertEqualInt(tupleDestructured(), 1005, "destructured local")
  assertEqualInt(literalDestructured(), 1005, "destructured literal")
  assertEqualInt(tupleMatched(), 1005, "matched")
  assertEqualInt(tupleNested(), 1003, "nested")
}

test "Ok, Err and newList elements of an unannotated tuple" {
  assertEqualInt(tupleOkErr(), 302, "Ok and Err")
  assertEqualInt(tupleNewListStores(), 207, "newList stores")
  assertEqualInt(tupleHoldsOpenLocal(), 7, "an open local element")
  assertEqualInt(tupleReassigned(true) + tupleReassigned(false), 1012, "reassigned")
}

test "unannotated Ok and Err locals" {
  assertEqualInt(okLocal(), 2, "Ok")
  assertEqualInt(errLocal(), 300, "Err")
}

test "if and match values assigned to a field" {
  assertEqualInt(fieldIf(true) + fieldIf(false), 1005, "if")
  assertEqualInt(fieldMatch(0) + fieldMatch(1), 1005, "match")
  assertEqualInt(fieldNone(), 1000, "bare None")
  assertEqualInt(fieldBlock(true) + fieldBlock(false), 1005, "nested block arms")
  assertEqualInt(fieldOkErr(true) + fieldOkErr(false), 207, "Ok and Err")
  assertEqualInt(fieldNewList(true) + fieldNewList(false), 11, "newList")
  assertEqualInt(nestedField(true) + nestedField(false), 1005, "nested field")
  assertEqualInt(selfField(true) + selfField(false), 1005, "self field")
  assertEqualInt(genericField(true) + genericField(false), 1005, "generic record field")
}

test "if and match values assigned to an element" {
  assertEqualInt(listElement(true) + listElement(false), 1005, "List element")
  assertEqualInt(mapValue(true) + mapValue(false), 307, "Map value")
  assertEqualInt(sliceElement(true) + sliceElement(false), 1005, "slice element")
  assertEqualLong(compoundField(true) + compoundField(false), 23i64, "compound")
}

test "awaiting variants" {
  assertEqualInt(await asyncTuple(), 1005, "tuple")
  assertEqualInt(await asyncTupleDestructured(), 1005, "destructured tuple")
  assertEqualInt(await asyncTupleOkErr(), 305, "Ok and Err tuple")
  assertEqualInt(await asyncTupleAfter(), 1010, "tuple before an await")
  assertEqualInt(await asyncOkLocal(), 205, "Err local")
  assertEqualInt(await asyncFieldIf(true) + await asyncFieldIf(false), 1015, "field")
  assertEqualInt(await asyncFieldMatchAwait(0) + await asyncFieldMatchAwait(1), 305, "field, awaiting arm")
  assertEqualInt(await asyncElementAwait(true) + await asyncElementAwait(false), 1005, "element, awaiting arm")
  assertEqualInt(await asyncScrut(), 1005, "matched tuple literal")
}

test "names bound to a nested sub-tuple" {
  assertEqualInt(subTupleSink(), 1003, "sink")
  assertEqualInt(subTupleLiteral(), 303, "destructured literal, Ok and Err")
  assertEqualInt(subTupleStores(), 203, "newList stores")
  assertEqualInt(subTupleMatched(), 1003, "matched")
  assertEqualInt(subTupleDeep(), 1006, "two levels down")
  assertEqualInt(wholeTupleArm(), 1005, "an arm binding the whole tuple")
}

test "type parameters reached through a pattern-bound name" {
  val xs = listViaLocal(3, 4)
  assertEqualInt(xs[0] + xs[1] + xs.count * 100, 207, "newList, destructured")
  val ys = listViaArm(5)
  assertEqualInt(ys[0] + ys.count * 100, 105, "newList, matched")
  val m = mapViaLocal("a", 7)
  assertEqualInt(m["a"] + m.count * 100, 107, "newMap")
  assertEqualInt(optValue(optViaLocal(5, true)) + optValue(optViaLocal(5, false)), 1005, "None")
  assertEqualInt(resValue(resViaArm(5, true)) + resValue(resViaArm(5, false)), 305, "Ok and Err")
  val zs: List[Int] = newList()
  assertEqualInt(typedPairParam((zs, 3), 9), 13, "a typed tuple parameter")
}

test "a tuple literal matched directly" {
  assertEqualInt(scrutNone(), 1005, "None")
  assertEqualInt(scrutOkErr(), 302, "Ok and Err")
  assertEqualInt(scrutNewList(), 207, "newList")
  assertEqualInt(scrutWhole(), 1005, "an arm binding the whole tuple")
  assertEqualInt(scrutDoubleParen(), 1005, "double parentheses")
  assertEqualInt(scrutTripleParen(), 302, "triple parentheses")
  val xs = scrutGeneric(8)
  assertEqualInt(xs[0] + xs.count * 100, 108, "in a generic body")
}

test "wider tuples" {
  assertEqualInt(wideArgument(), 1004, "argument")
  assertEqualInt(wideDestructured(), 1203, "destructured literal")
  assertEqualInt(wideNested(), 1007, "nested")
  assertEqualInt(wideScrutinee(), 1008, "matched literal")
}
