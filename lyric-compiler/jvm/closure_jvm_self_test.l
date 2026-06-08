//! closure_jvm_self_test.l — executable regression test for J2b / B-1: closures
//! (lambda values) on the self-hosted JVM backend (docs/44 §5 J2 lambda-lift,
//! epic #2663, #2665).
//!
//! Before this slice every general `ELambda` panicked in `Jvm.Codegen`
//! ("ELambda not supported — pass lambdas directly to Std.Jvm.catch"); only the
//! literal-lambda `Std.Jvm.catch` intrinsic was special-cased.  A lambda value
//! (`val f = { x -> … }`), passing a lambda to a higher-order function,
//! capturing an enclosing `val`, and returning a `Result[T, E]` from a lambda
//! were all unsupported on `--target jvm`.
//!
//! This module asserts the runtime values, under `java`, of:
//!   • a non-capturing lambda (`{ x -> x + 1 }`) called via its value;
//!   • a capturing lambda (`{ x -> x + n }`, `n` a captured `val`) — proves the
//!     synthesised closure class holds the capture as a ctor-bound field;
//!   • passing a lambda to a higher-order function and invoking it inside;
//!   • a lambda returning `Result[Int, String]` (drives J4 erased generics
//!     through the closure ABI — payload boxing + checkcast/unbox round-trip);
//!   • a multi-argument lambda and a String-payload capture.
//!
//! Each lambda lowers to a `<pkg>$Lambda$<n>` inner class implementing the
//! package-shared `<pkg>/Lyric$Lambda` functional interface (uniform
//! Object[]-packing ABI; params/return erased to `Object`, primitives boxed in /
//! checkcast+unboxed out).  Capture is by value (snapshot) per docs/01 §5.4 for
//! `val` bindings.
//!
//! Run in CI via the native `lyric test --target jvm`: the runnable program
//! synthesised from the `test` blocks is compiled IN-PROCESS through the
//! self-hosted `Jvm.Bridge` (`compileToJarBundled` bundles the user package plus
//! its transitive stdlib-import closure into one runnable JAR), run under `java`,
//! and every embedded assertion is checked.  Imports only `Std.*` (Std.Core
//! gives `Result`), so no `LYRIC_LOAD_COMPILER=1` is needed.
//!
//!   lyric test --target jvm lyric-compiler/jvm/closure_jvm_self_test.l
@test_module
package Lyric.ClosureJvmSelfTest

import Std.Core
import Std.Testing

// Higher-order functions whose `(…) -> R` parameter type lets the lambda be
// invoked through the closure value inside the callee.
func applyInt(f: in (Int) -> Int, x: in Int): Int {
  f(x)
}

func applyInt2(f: in (Int, Int) -> Int, a: in Int, b: in Int): Int {
  f(a, b)
}

func applyRes(f: in (Int) -> Result[Int, String], x: in Int): Result[Int, String] {
  f(x)
}

// ─────────────────────────────────────────────────────────────────────────────
// Non-capturing lambda, called via its value.
// ─────────────────────────────────────────────────────────────────────────────
test "non-capturing lambda value calls correctly" {
  val f: (Int) -> Int = { x: Int -> x + 1 }
  assertEqualInt(f(2), 3, "f(2) == 3")
}

// ─────────────────────────────────────────────────────────────────────────────
// Capturing lambda — captures an enclosing `val` by value.
// ─────────────────────────────────────────────────────────────────────────────
test "capturing lambda reads captured val" {
  val n = 10
  val g: (Int) -> Int = { x: Int -> x + n }
  assertEqualInt(g(5), 15, "g(5) with captured n=10 == 15")
}

test "capturing lambda captures multiple vals" {
  val a = 3
  val b = 100
  val h: (Int) -> Int = { x: Int -> x + a + b }
  assertEqualInt(h(1), 104, "h(1) with a=3,b=100 == 104")
}

// ─────────────────────────────────────────────────────────────────────────────
// Passing a lambda to a higher-order function.
// ─────────────────────────────────────────────────────────────────────────────
test "lambda passed to higher-order function" {
  val r = applyInt({ x: Int -> x * 2 }, 21)
  assertEqualInt(r, 42, "applyInt(double, 21) == 42")
}

test "captured lambda passed to higher-order function" {
  val bump = 7
  val r = applyInt({ x: Int -> x + bump }, 35)
  assertEqualInt(r, 42, "applyInt(+7, 35) == 42")
}

test "multi-argument lambda via higher-order function" {
  val r = applyInt2({ a: Int, b: Int -> a * b }, 6, 7)
  assertEqualInt(r, 42, "applyInt2(mul, 6, 7) == 42")
}

// ─────────────────────────────────────────────────────────────────────────────
// Lambda returning Result[Int, String] — exercises J4 erased generics through
// the closure ABI (payload boxing on construction + checkcast/unbox on extract).
// ─────────────────────────────────────────────────────────────────────────────
test "lambda returning Result Ok" {
  val safeDiv: (Int) -> Result[Int, String] = { d: Int -> if d == 0 { Err("div by zero") } else { Ok(100 / d) } }
  val r = safeDiv(4)
  val v = match r { case Ok(x) -> x; case Err(_) -> -1 }
  assertEqualInt(v, 25, "safeDiv(4) -> Ok(25)")
}

test "lambda returning Result Err" {
  val safeDiv: (Int) -> Result[Int, String] = { d: Int -> if d == 0 { Err("div by zero") } else { Ok(100 / d) } }
  val r = safeDiv(0)
  val s = match r { case Ok(_) -> "no"; case Err(m) -> m }
  assertEqual(s, "div by zero", "safeDiv(0) -> Err(div by zero)")
}

test "Result-returning lambda through higher-order function" {
  val r = applyRes({ x: Int -> Ok(x + 1) }, 41)
  val v = match r { case Ok(x) -> x; case Err(_) -> -1 }
  assertEqualInt(v, 42, "applyRes(succ, 41) -> Ok(42)")
}

// ─────────────────────────────────────────────────────────────────────────────
// String-payload capture (a captured reference, not a primitive).
// ─────────────────────────────────────────────────────────────────────────────
test "capturing lambda over a String val" {
  val prefix = "hi-"
  val withPrefix: (String) -> String = { s: String -> prefix + s }
  assertEqual(withPrefix("there"), "hi-there", "withPrefix(there) with captured prefix")
}
