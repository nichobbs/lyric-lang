//! hof_type_propagation_self_test.l — #1986: HOF-type propagation for lambda
//! parameter type inference.
//!
//! When a lambda is passed directly as an argument to a higher-order function
//! (HOF) whose corresponding parameter type is `(ParamType) -> RetType`, the
//! codegen can propagate `ParamType` to the lambda's un-annotated parameter,
//! enabling `{ x -> x + 1 }` to compile when passed to `apply((Int) -> Int)`.
//! Before this PR the only supported form was the explicitly annotated
//! `{ x: Int -> x + 1 }`.
//!
//! The four scenarios from the CI inline-script (PR #1986, ci.yml lines
//! 1167–1206) are replicated here as a permanent `@test_module` regression
//! guard alongside the implementation.
//!
//! Run in CI via native `lyric test --target dotnet`:
//!
//!   lyric test lyric-compiler/lyric/hof_type_propagation_self_test.l
//!
//! MSIL target only; JVM parity is tracked under epic #1470.
@test_module
package Lyric.HofTypePropagationSelfTest

import Std.Core
import Std.Testing

// HOFs whose parameter types carry the hint used to propagate the lambda's
// un-annotated param types.
func apply1(f: in (Int) -> Int, x: in Int): Int {
  f(x)
}

func apply2(f: in (Int, Int) -> Int, a: in Int, b: in Int): Int {
  f(a, b)
}

func applyB(f: in (Int) -> Bool, x: in Int): Bool {
  f(x)
}

func applyS(f: in (String) -> Int, s: in String): Int {
  f(s)
}

test "annotated-param lambda (regression from #1961)" {
  val r = apply1({ x: Int -> x + 1 }, 10)
  assertEqualInt(r, 11, "{ x: Int -> x+1 }(10) == 11")
}

test "propagated-param lambda (the new path in #1986)" {
  val r = apply1({ x -> x + 1 }, 10)
  assertEqualInt(r, 11, "{ x -> x+1 }(10) == 11")
}

test "multi-arg propagated-param lambda" {
  val r = apply2({ a, b -> a * b }, 6, 7)
  assertEqualInt(r, 42, "{ a, b -> a*b }(6,7) == 42")
}

test "Bool-returning propagated-param lambda" {
  val t = applyB({ x -> x > 5 }, 9)
  val f = applyB({ x -> x > 5 }, 3)
  assertTrue(t, "{ x -> x>5 }(9) == true")
  assertTrue(not f, "{ x -> x>5 }(3) == false")
}

test "String-param propagated lambda" {
  val r = applyS({ s -> s.length }, "hello")
  assertEqualInt(r, 5, "{ s -> s.length }(\"hello\") == 5")
}
