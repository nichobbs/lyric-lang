//! closure_unannotated_result_self_test.l — calling a function value bound
//! to an unannotated local yields the closure's real result (#7711).
//!
//! On `--target dotnet` a closure is a uniform boxed `Func<object, ...>`, so
//! a call through it returns a boxed `object` the call site must unbox to the
//! closure's result type.  Codegen learned that type from the binding's
//! annotation or from a syntactic guess at the lambda body, which fails for a
//! body that reads a captured local (`{ -> base + 1 }`): the call then
//! returned the box's object reference as an `Int`.  The type checker now
//! records each unannotated function-valued local's checked type and
//! `Lyric.Mono.desugarCheckedFile` writes it onto the binding.
//!
//! Runs on both targets:
//!   lyric test --target dotnet lyric-compiler/lyric/closure_unannotated_result_self_test.l
//!   lyric test --target jvm lyric-compiler/lyric/closure_unannotated_result_self_test.l
@test_module
package ClosureUnannotatedResultTest

import Std.Core
import Std.Testing

record Pt {
  x: Int
  y: Int
}

func tailCall(base: in Int): Int {
  val inner = { -> base + 1 }
  inner()
}

func afterReturn(base: in Int): Int {
  val inner = { -> base + 1 }
  return inner()
}

func boundResult(base: in Int): Int {
  val inner = { -> base + 1 }
  val r = inner()
  r + 0
}

func nestedClosure(base: in Int): Int {
  val h = { -> val inner = { -> base + 1 }; inner() }
  h()
}

func nestedCapturedTwice(base: in Int, extra: in Int): Int {
  val scaled = base * 3
  val h = { -> val inner = { -> scaled + extra + 1 }; inner() }
  h()
}

func outerClosureCalledInside(base: in Int): Int {
  val inner = { -> base + 1 }
  val h = { -> inner() * 2 }
  h()
}

func longResult(base: in Long): Long {
  val inner = { -> base * 2 }
  inner()
}

func boolResult(base: in Int): Bool {
  val inner = { -> base > 3 }
  inner()
}

func doubleResult(base: in Double): Double {
  val inner = { -> base + 0.5 }
  inner()
}

func stringResult(base: in Int): String {
  val inner = { -> "v" + toString(base) }
  inner()
}

func recordResult(base: in Int): Int {
  val inner = { -> Pt(x = base, y = base + 1) }
  val p = inner()
  p.x + p.y
}

func optionResult(base: in Int): Int {
  val inner = { -> Some(base + 1) }
  match inner() {
    case Some(v) -> v
    case None -> 0
  }
}

func unitResult(base: in Int): Int {
  var acc = 0
  val bump = { -> acc = acc + base }
  bump()
  bump()
  acc
}

func withArgument(base: in Int): Int {
  val add = { x: Int -> x + base }
  add(3) + add(4)
}

func varBinding(base: in Int): Int {
  var f = { -> base + 1 }
  val first = f()
  f = { -> base + 10 }
  first + f()
}

func applyTwice(f: in () -> Int): Int {
  f() + f()
}

func passedAsParameter(base: in Int): Int {
  val inner = { -> base + 1 }
  applyTwice(inner)
}

func makeAdder(base: in Int): (Int) -> Int {
  { x: Int -> x + base }
}

func returnedFromFunction(base: in Int): Int {
  val add = makeAdder(base)
  val r = add(5)
  r + 0
}

func twice(x: in Int): Int {
  x * 2
}

func bareFunctionValue(base: in Int): Int {
  val f = twice
  f(base) + 0
}

func conditionalClosure(flag: in Bool, base: in Int): Int {
  val f = if flag { { -> base + 1 } } else { { -> base - 1 } }
  f()
}

test "tail-position call" {
  assertEqualInt(tailCall(7), 8, "tail")
}

test "call after return" {
  assertEqualInt(afterReturn(7), 8, "return")
}

test "call bound to an unannotated val" {
  assertEqualInt(boundResult(7), 8, "bound")
}

test "nested closure" {
  assertEqualInt(nestedClosure(7), 8, "nested")
}

test "nested closure reading two captures" {
  assertEqualInt(nestedCapturedTwice(7, 5), 27, "nested twice")
}

test "captured closure called inside another" {
  assertEqualInt(outerClosureCalledInside(7), 16, "captured closure")
}

test "Long result" {
  assertEqualLong(longResult(21i64), 42i64, "long")
}

test "Bool result" {
  assertTrue(boolResult(7), "bool true")
  assertFalse(boolResult(2), "bool false")
}

test "Double result" {
  assertTrue(doubleResult(1.0) == 1.5, "double")
}

test "String result" {
  assertEqual(stringResult(4), "v4", "string")
}

test "record result" {
  assertEqualInt(recordResult(4), 9, "record")
}

test "Option[Int] result" {
  assertEqualInt(optionResult(4), 5, "option")
}

test "Unit result" {
  assertEqualInt(unitResult(4), 8, "unit")
}

test "closure with an argument" {
  assertEqualInt(withArgument(10), 27, "argument")
}

test "var-bound closure reassigned" {
  assertEqualInt(varBinding(1), 13, "var")
}

test "closure passed as a parameter" {
  assertEqualInt(passedAsParameter(4), 10, "parameter")
}

test "closure returned from a function" {
  assertEqualInt(returnedFromFunction(2), 7, "returned")
}

test "bare function value" {
  assertEqualInt(bareFunctionValue(6), 12, "bare")
}

test "closure chosen by if" {
  assertEqualInt(conditionalClosure(true, 5), 6, "if then")
  assertEqualInt(conditionalClosure(false, 5), 4, "if else")
}
