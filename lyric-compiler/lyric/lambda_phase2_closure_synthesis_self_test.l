//! lambda_phase2_closure_synthesis_self_test.l — regression tests for Phase 2
//! closure class synthesis and instance method conversion.
//!
//! Phase 2 (Epic #1877 Part 2) replaces Phase 1's object[] array mechanism with
//! strongly-typed closure record instances. This eliminates boxing/unboxing
//! overhead and enables JIT inlining of capture access.
//!
//! These tests verify that:
//! 1. Closure records are synthesized for lambdas with captures
//! 2. Typed field access works correctly (no boxing/unboxing)
//! 3. Instance methods on closure records function properly
//! 4. Hoisted vars in closures are stored in closure record fields
//! 5. Re-captured variables from nested lambdas work correctly
//!
//! Run with:
//!   lyric test lyric-compiler/lyric/lambda_phase2_closure_synthesis_self_test.l
//!
//! Compiles through the self-hosted `Msil.Bridge`; no F# shim needed.
//! Imports only `Std.*`.

@test_module
package LambdaPhase2ClosureSynthesisTest

import Std.Core
import Std.Testing

// ─── Basic typed captures ───────────────────────────────────────────────────

test "single Int capture" {
  val x = 42
  val f = { -> x }
  assertEqualInt(f(), 42, "single Int capture")
}

test "single String capture" {
  val s = "hello"
  val f = { -> s }
  assertEqualString(f(), "hello", "single String capture")
}

test "mixed type captures (Int + String)" {
  val n = 10
  val s = "test"
  val f = { -> n + Str.len(s) }
  assertEqualInt(f(), 14, "mixed type captures")
}

test "multiple Int captures" {
  val a = 3
  val b = 5
  val c = 7
  val f = { -> a + b + c }
  assertEqualInt(f(), 15, "multiple Int captures")
}

test "lambda with typed parameters and captures" {
  val cap = 100
  val f = { x: Int -> x + cap }
  assertEqualInt(f(20), 120, "lambda with param and capture")
}

// ─── Mutable captures (hoisted vars) ────────────────────────────────────────

test "mutable capture in Phase 2" {
  var counter = 0
  val inc = { -> counter = counter + 1; counter }
  assertEqualInt(inc(), 1, "mutable capture: first increment")
  assertEqualInt(inc(), 2, "mutable capture: second increment")
  assertEqualInt(counter, 2, "outer var updated via closure")
}

test "multiple mutable captures" {
  var x = 10
  var y = 20
  val swap = { -> val tmp = x; x = y; y = tmp }
  swap()
  assertEqualInt(x, 20, "first var after swap")
  assertEqualInt(y, 10, "second var after swap")
}

// ─── Nested closures with Phase 2 ───────────────────────────────────────────

test "nested closures with typed captures" {
  val outer = 5
  val f = { ->
    val inner = { -> outer * 2 }
    inner()
  }
  assertEqualInt(f(), 10, "nested closure with typed capture")
}

test "triple-nested closure capture" {
  val base = 2
  val f1 = { ->
    val f2 = { ->
      val f3 = { -> base * base }
      f3()
    }
    f2()
  }
  assertEqualInt(f1(), 4, "triple-nested with typed capture")
}

test "nested closure captures closure result" {
  val x = 10
  val makeAdder = { ->
    val adder = { y: Int -> x + y }
    adder
  }
  val adder = makeAdder()
  assertEqualInt(adder(5), 15, "nested closure capture of closure result")
}

// ─── Higher-order functions with Phase 2 closures ─────────────────────────

test "map with closure as argument" {
  val factor = 2
  val multiply = { x: Int -> x * factor }
  val result = Std.Core.map([1, 2, 3], multiply)
  assertEqualInt(Std.Core.len(result), 3, "map result length")
}

test "filter with closure predicate" {
  val threshold = 5
  val isGreater = { x: Int -> x > threshold }
  val result = Std.Core.filter([1, 5, 10, 3, 8], isGreater)
  assertEqualInt(Std.Core.len(result), 2, "filter with closure predicate")
}

// ─── Complex capture scenarios ───────────────────────────────────────────────

test "closure reading same capture multiple times" {
  val value = 7
  val f = { -> value + value + value }
  assertEqualInt(f(), 21, "same capture used multiple times")
}

test "closure with String operations" {
  val prefix = "Hello"
  val greeting = { name: String -> prefix + " " + name }
  assertEqualString(greeting("World"), "Hello World", "String closure operations")
}

test "closure preserving type across calls" {
  val step = 3
  var total = 0
  val accumulate = { ->
    total = total + step
    total
  }
  assertEqualInt(accumulate(), 3, "accumulate call 1")
  assertEqualInt(accumulate(), 6, "accumulate call 2")
  assertEqualInt(accumulate(), 9, "accumulate call 3")
}

// ─── Phase 2 fallback to Phase 1 (non-capturing lambdas) ──────────────────

test "non-capturing lambda (Phase 1 fallback)" {
  val add = { x: Int; y: Int -> x + y }
  assertEqualInt(add(3, 4), 7, "non-capturing lambda")
}

test "lambda without parameters or captures" {
  val constant = { -> 42 }
  assertEqualInt(constant(), 42, "lambda without captures")
}
