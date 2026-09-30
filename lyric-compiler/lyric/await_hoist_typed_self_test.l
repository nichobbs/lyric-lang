//! await_hoist_typed_self_test.l — dual-target runtime regression test for
//! the operands the await hoist binds (#7823).
//!
//! In an `async func`, `Lyric.AwaitHoist` binds every operand evaluated
//! before an `await` in the same expression to a fresh local, so the await
//! never suspends with operands on the MSIL evaluation stack.  The local had
//! no annotation, so an operand that carries no evidence of its own type
//! argument lost the type its position expects: `addOpt(None, await five())`
//! built the `None` as an `Option<object>` on --target dotnet and passed it
//! where an `Option<int>` was expected ("match not exhaustive"), and
//! `Ok(2)`, `Err("ab")`, `newList()` and `[None, Some(await five())]` failed
//! the same way (`InvalidCastException`).
//!
//! The type checker now records the type of each such operand's position,
//! `Lyric.Mono` binds the operand to a local of that type, and the hoist keeps
//! the annotation on its fresh local.  Every case really suspends
//! (`Std.Task.delay`) and runs on both targets.
//!
//! Run via `lyric test`:
//!
//!   lyric test --target dotnet lyric-compiler/lyric/await_hoist_typed_self_test.l
//!   lyric test --target jvm lyric-compiler/lyric/await_hoist_typed_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.AwaitHoistTypedSelfTest

import Std.Core
import Std.Collections
import Std.Task
import Std.Testing

async func five(): Int {
  await Std.Task.delay(5)
  5
}

async func someFive(): Option[Int] {
  await Std.Task.delay(5)
  Some(5)
}

async func okFive(): Result[Int, String] {
  await Std.Task.delay(5)
  Ok(5)
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

func addRes(a: in Result[Int, String], b: in Int): Int {
  resValue(a) + b
}

func addList(a: in List[Int], b: in Int): Int {
  a.add(b)
  a.count * 10 + a[0]
}

func addMap(m: in Map[String, Int], b: in Int): Int {
  m.add("k", b)
  m.count * 10 + m["k"]
}

func addOptGeneric[T](a: in Option[T], b: in T, fallback: in T): T {
  match a {
    case Some(v) -> v
    case None -> if b == fallback { fallback } else { b }
  }
}

func sumOpts(xs: in slice[Option[Int]]): Int {
  var t = 0
  for o in xs {
    t = t + optValue(o)
  }
  t
}

func sumResults(xs: in slice[Result[Int, String]]): Int {
  var t = 0
  for r in xs {
    t = t + resValue(r)
  }
  t
}

func sumOptList(xs: in List[Option[Int]]): Int {
  var t = 0
  for o in xs {
    t = t + optValue(o)
  }
  t
}

func pairValue(p: in (Option[Int], Int)): Int {
  val (o, n) = p
  optValue(o) + n
}

record OptPair {
  o: Option[Int]
  n: Int

  func total(self: in OptPair, k: in Int): Int {
    optValue(self.o) + self.n + k
  }

  func plus(self: in OptPair, extra: in Option[Int], k: in Int): Int {
    optValue(self.o) + optValue(extra) + self.n + k
  }
}

record OptCell {
  var o: Option[Int]
}

record Holder[T] {
  value: Option[T]
  fallback: T
}

func holderValue(h: in Holder[Int]): Int {
  match h.value {
    case Some(v) -> v
    case None -> h.fallback
  }
}

union Shape {
  case Pair(first: Option[Int], second: Int)
  case Solo(only: Int)
}

func shapeValue(s: in Shape): Int {
  match s {
    case Pair(f, n) -> optValue(f) + n
    case Solo(o) -> o
  }
}

async func noneArg(): Int {
  addOpt(None, await five())
}

async func okArg(): Int {
  addRes(Ok(2), await five())
}

async func errArg(): Int {
  addRes(Err("ab"), await five())
}

async func newListArg(): Int {
  addList(newList(), await five())
}

async func newMapArg(): Int {
  addMap(newMap(), await five())
}

async func genericCalleeArg(): Int {
  addOptGeneric(None, await five(), 7)
}

async func echo[T](x: in T): T {
  await Std.Task.delay(5)
  x
}

func countNone[T](a: in Option[T], b: in T): Int {
  match a {
    case Some(_) -> 1
    case None -> 1000
  }
}

async func genericBody[T](fallback: in T, pick: in T): T {
  addOptGeneric(None, await echo(pick), fallback)
}

async func noneBeforeAwaitInGeneric[T](x: in T): Int {
  val held: Holder[T] = Holder(value = None, fallback = await echo(x))
  countNone(None, await echo(x)) + countNone(held.value, x)
}

async func listLiteralNone(): Int {
  sumOpts([None, Some(await five())])
}

async func listLiteralLoop(): Int {
  var t = 0
  for o in [None, Some(await five()), None] {
    t = t + optValue(o)
  }
  t
}

async func listLiteralResults(): Int {
  sumResults([Ok(1), Err("abc"), Ok(await five())])
}

async func annotatedListLiteral(): Int {
  val xs: List[Option[Int]] = [None, Some(await five())]
  sumOptList(xs)
}

async func recordCtorArg(): Int {
  val p = OptPair(o = None, n = await five())
  p.total(0)
}

async func genericRecordCtorArg(): Int {
  val h: Holder[Int] = Holder(value = None, fallback = await five())
  holderValue(h)
}

async func unionCtorArg(): Int {
  shapeValue(Pair(first = None, second = await five()))
}

async func binopOperand(): Bool {
  None == await someFive()
}

async func binopOperandNested(): Bool {
  Ok(5) == await okFive()
}

async func methodArg(): Int {
  val p = OptPair(o = Some(1), n = 2)
  p.plus(None, await five())
}

async func methodReceiver(): Int {
  OptPair(o = None, n = 2).total(await five())
}

async func tupleElement(): Int {
  pairValue((None, await five()))
}

async func valTuple(): Int {
  val t: (Option[Int], Int) = (None, await five())
  pairValue(t)
}

async func tailTuple(): (Option[Int], Int) {
  (None, await five())
}

async func returnTuple(): (Option[Int], Int) {
  return (None, await five())
}

async func assignTuple(): Int {
  var t: (Option[Int], Int) = (Some(1), 0)
  t = (None, await five())
  pairValue(t)
}

async func nestedTuple(): Int {
  val t: ((Option[Int], Int), Int) = ((None, 1), await five())
  val (inner, n) = t
  pairValue(inner) + n
}

async func nestedHazardTuple(): Int {
  val t: ((Option[Int], Int), Int) = ((None, await five()), 2)
  val (inner, n) = t
  pairValue(inner) + n
}

async func ifArmOperand(c: in Bool): Int {
  pairValue((if c { None } else { Some(await five()) }, 1))
}

async func matchArmOperand(k: in Int): Int {
  optValue(match k { case 0 -> None; case _ -> Some(await five()) }) + optValue(None)
}

async func fieldAssign(c: in Bool): Int {
  val cell = OptCell(o = Some(1))
  cell.o = if c { None } else { Some(await five()) }
  optValue(cell.o)
}

async func propagateOperand(): Result[Int, String] {
  Ok(addRes(Err("abc"), (await okFive())?))
}

test "a None argument before an awaited one" {
  assertEqualInt(await noneArg(), 1005, "None arg")
}

test "Ok and Err arguments before an awaited one" {
  assertEqualInt(await okArg(), 7, "Ok arg")
  assertEqualInt(await errArg(), 205, "Err arg")
}

test "newList and newMap arguments before an awaited one" {
  assertEqualInt(await newListArg(), 15, "newList arg")
  assertEqualInt(await newMapArg(), 15, "newMap arg")
}

test "a None argument to a generic callee" {
  assertEqualInt(await genericCalleeArg(), 5, "generic callee")
}

test "a None argument inside a generic async body" {
  assertEqualInt(await genericBody(3, 9), 9, "generic body, Int")
  assertEqual(await genericBody("a", "a"), "a", "generic body, String")
  assertEqualInt(await noneBeforeAwaitInGeneric(4), 2000, "Option[T], Int")
  assertEqualInt(await noneBeforeAwaitInGeneric("s"), 2000, "Option[T], String")
}

test "list literals holding None before an awaited element" {
  assertEqualInt(await listLiteralNone(), 1005, "passed")
  assertEqualInt(await listLiteralLoop(), 2005, "iterated")
  assertEqualInt(await listLiteralResults(), 306, "Ok/Err")
  assertEqualInt(await annotatedListLiteral(), 1005, "List-typed")
}

test "constructor arguments before an awaited one" {
  assertEqualInt(await recordCtorArg(), 1005, "record")
  assertEqualInt(await genericRecordCtorArg(), 5, "generic record")
  assertEqualInt(await unionCtorArg(), 1005, "union case")
}

test "a left operand before an awaited right one" {
  assertFalse(await binopOperand(), "None == Some(5)")
  assertTrue(await binopOperandNested(), "Ok(5) == Ok(5)")
}

test "method receivers and arguments before an awaited argument" {
  assertEqualInt(await methodArg(), 1008, "method argument")
  assertEqualInt(await methodReceiver(), 1007, "method receiver")
}

test "a tuple element before an awaited one" {
  assertEqualInt(await tupleElement(), 1005, "tuple element")
}

test "tuple literals holding None before an awaited element" {
  assertEqualInt(await valTuple(), 1005, "val initializer")
  assertEqualInt(pairValue(await tailTuple()), 1005, "function value")
  assertEqualInt(pairValue(await returnTuple()), 1005, "return")
  assertEqualInt(await assignTuple(), 1005, "assignment")
  assertEqualInt(await nestedTuple(), 1006, "nested, None beside the await")
  assertEqualInt(await nestedHazardTuple(), 1007, "nested, None in the awaiting tuple")
}

test "an if or match operand whose arm awaits" {
  assertEqualInt(await ifArmOperand(true), 1001, "if, None arm")
  assertEqualInt(await ifArmOperand(false), 6, "if, awaiting arm")
  assertEqualInt(await matchArmOperand(0), 2000, "match, None arm")
  assertEqualInt(await matchArmOperand(1), 1005, "match, awaiting arm")
}

test "a field assignment whose value awaits" {
  assertEqualInt(await fieldAssign(true), 1000, "None arm")
  assertEqualInt(await fieldAssign(false), 5, "awaiting arm")
}

test "an operand before an awaited, propagated one" {
  match await propagateOperand() {
    case Ok(v) -> assertEqualInt(v, 305, "? operand")
    case Err(e) -> assertTrue(false, "unexpected Err " + e)
  }
}
