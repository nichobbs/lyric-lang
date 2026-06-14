//! stdlib_generic_iface_self_test.l — regression tests for stdlib generic types
//! (`Result`, `Option`) instantiated with **interface** type parameters (#3502).
//!
//! Bug: `isOk` / `isErr` on `Result[InterfaceType, E]` threw "method not found"
//! at runtime because the self-hosted MSIL codegen built the `newobj` TypeSpec
//! from the *concrete argument type* (`T1`) rather than the *declared return type*
//! (`Thing`).  On the CLR, generics are invariant, so
//! `isinst Result_Ok<Thing, String>` returned null when the value was
//! `Result_Ok<T1, String>` — even though T1 implements Thing — causing the
//! match-exhaustiveness guard to panic.
//!
//! Fix: `buildGenericCaseCtorTok` and `buildInBundleGenericCtorTok` now prefer
//! the context type args (derived from the enclosing function's declared return
//! type or a caller-supplied hint) over the inferred argument types when building
//! the construction TypeSpec.  The `isinst` TypeSpec in the consumer's match was
//! always correct; the construction TypeSpec is what was wrong.
//!
//! Run via native `lyric test` (no `LYRIC_LOAD_COMPILER=1` needed — imports
//! only `Std.*`):
//!
//!   lyric test lyric-compiler/lyric/stdlib_generic_iface_self_test.l
//!
//! Covers both MSIL (`--target dotnet`) and JVM (`--target jvm`) pipelines:
//! `lyric test --target jvm lyric-compiler/lyric/stdlib_generic_iface_self_test.l`
@test_module
package Lyric.StdlibGenericIfaceSelfTest

import Std.Core
import Std.Testing

// ─────────────────────────────────────────────────────────────────────────────
// Shared types used across all tests below.
// ─────────────────────────────────────────────────────────────────────────────
pub interface Shape {
  func area(): Int
}

pub record Square {
  side: Int
}

pub record Circle {
  radius: Int
}

impl Shape for Square {
  func area(): Int {
    return self.side * self.side
  }
}

impl Shape for Circle {
  func area(): Int {
    return self.radius * self.radius * 3
  }
}

// Helpers that return stdlib generic types instantiated at an interface type.
func squareAsResult(): Result[Shape, String] {
  return Ok(Square(side = 4))
}

func errResult(): Result[Shape, String] {
  return Err("bad")
}

func circleAsResult(): Result[Shape, String] {
  return Ok(Circle(radius = 5))
}

func squareAsOption(): Option[Shape] {
  return Some(Square(side = 3))
}

func noneOption(): Option[Shape] {
  return None
}

// ─────────────────────────────────────────────────────────────────────────────
// Result[InterfaceType, String] — construction and isOk / isErr
// ─────────────────────────────────────────────────────────────────────────────
test "isOk on Result[Shape,String] Ok case" {
  assertTrue(isOk(squareAsResult()), "isOk must return true for Ok(Square(...))")
}

test "isErr on Result[Shape,String] Err case" {
  assertTrue(isErr(errResult()), "isErr must return true for Err(...)")
}

test "isOk on Result[Shape,String] Err case returns false" {
  assertFalse(isOk(errResult()), "isOk must return false for Err(...)")
}

test "isErr on Result[Shape,String] Ok case returns false" {
  assertFalse(isErr(squareAsResult()), "isErr must return false for Ok(...)")
}

// ─────────────────────────────────────────────────────────────────────────────
// Result[InterfaceType, String] — match arm dispatch and field extraction
// ─────────────────────────────────────────────────────────────────────────────
test "match Result[Shape,String] Ok arm extracts area" {
  val r: Result[Shape, String] = squareAsResult()
  val got = match r { case Ok(s) -> s.area(); case Err(_) -> -1 }
  assertEqualInt(got, 16, "Square(side=4).area() == 16")
}

test "match Result[Shape,String] Err arm extracts message" {
  val r: Result[Shape, String] = errResult()
  val got = match r { case Ok(_) -> "unexpected"; case Err(msg) -> msg }
  assertEqual(got, "bad", "Err message must be 'bad'")
}

test "match Result[Shape,String] with Circle payload" {
  val r = circleAsResult()
  val got = match r { case Ok(s) -> s.area(); case Err(_) -> -1 }
  assertEqualInt(got, 75, "Circle(radius=5).area() == 75 (3*25)")
}

// ─────────────────────────────────────────────────────────────────────────────
// Option[InterfaceType] — construction and isSome / isNone
// ─────────────────────────────────────────────────────────────────────────────
test "isSome on Option[Shape] Some case" {
  assertTrue(isSome(squareAsOption()), "isSome must return true for Some(Square(...))")
}

test "isNone on Option[Shape] None case" {
  assertTrue(isNone(noneOption()), "isNone must return true for None")
}

test "isSome on Option[Shape] None case returns false" {
  assertFalse(isSome(noneOption()), "isSome must return false for None")
}

test "isNone on Option[Shape] Some case returns false" {
  assertFalse(isNone(squareAsOption()), "isNone must return false for Some(...)")
}

// ─────────────────────────────────────────────────────────────────────────────
// Option[InterfaceType] — match arm dispatch and field extraction
// ─────────────────────────────────────────────────────────────────────────────
test "match Option[Shape] Some arm extracts area" {
  val o: Option[Shape] = squareAsOption()
  val got = match o { case Some(s) -> s.area(); case None -> -1 }
  assertEqualInt(got, 9, "Square(side=3).area() == 9")
}

test "match Option[Shape] None arm reached" {
  val o: Option[Shape] = noneOption()
  val got = match o { case Some(_) -> 1; case None -> 0 }
  assertEqualInt(got, 0, "None must reach the None arm")
}

// ─────────────────────────────────────────────────────────────────────────────
// Chained: unwrapOr on Result[InterfaceType, String]
// ─────────────────────────────────────────────────────────────────────────────
test "unwrapResultOr on Result[Shape,String] Ok returns value area" {
  val r = squareAsResult()
  val s = unwrapResultOr(r, Square(side = 0))
  assertEqualInt(s.area(), 16, "unwrapResultOr(Ok(Square(4))) .area() == 16")
}

test "unwrapResultOr on Result[Shape,String] Err returns default area" {
  val r = errResult()
  val s = unwrapResultOr(r, Square(side = 7))
  assertEqualInt(s.area(), 49, "unwrapResultOr(Err, Square(7)) .area() == 49")
}

// ─────────────────────────────────────────────────────────────────────────────
// Nested generic + interface: Result[Option[Shape], String].
// Exercises the ctxIsGenericInst guard in the priority logic: the outer context
// type arg `Option[Shape]` (MGenericInstByName) must NOT override the inner
// `Some(Square(...))` construction's arg type, while `Shape` and `String` (not
// generic instantiations) must still win over the concrete arg types.
// ─────────────────────────────────────────────────────────────────────────────
func squareOptionResult(): Result[Option[Shape], String] {
  return Ok(Some(Square(side = 6)))
}

func noneOptionResult(): Result[Option[Shape], String] {
  return Ok(None)
}

func errOptionResult(): Result[Option[Shape], String] {
  return Err("fail")
}

test "isOk on Result[Option[Shape],String] Ok/Some case" {
  assertTrue(isOk(squareOptionResult()), "nested: isOk Ok(Some(Square))")
}

test "isErr on Result[Option[Shape],String] Err case" {
  assertTrue(isErr(errOptionResult()), "nested: isErr Err(...)")
}

test "match Result[Option[Shape],String] Ok/Some extracts area" {
  val r = squareOptionResult()
  val got = match r { case Ok(o) -> match o { case Some(s) -> s.area(); case None -> -1 }; case Err(_) -> -2 }
  assertEqualInt(got, 36, "nested: Square(side=6).area() == 36")
}

test "match Result[Option[Shape],String] Ok/None arm reached" {
  val r = noneOptionResult()
  val got = match r { case Ok(o) -> match o { case Some(_) -> 1; case None -> 0 }; case Err(_) -> -1 }
  assertEqualInt(got, 0, "nested: Ok(None) reaches None arm")
}

test "match Result[Option[Shape],String] Err arm reached" {
  val r = errOptionResult()
  val got = match r { case Ok(_) -> 1; case Err(msg) -> if msg == "fail" { 0 } else { 2 } }
  assertEqualInt(got, 0, "nested: Err('fail') reaches Err arm")
}
