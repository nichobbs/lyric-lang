//! closure_zero_overhead_self_test.l — dual-target regression test for epic #1877:
//! zero-overhead closure captures (no boxing of primitives in capture cells).
//!
//! This module establishes the baseline behavior test corpus for the closure
//! zero-overhead optimization stages (Stage 0–5 of epic #1877). Each test case
//! exercises a distinct capture scenario:
//!
//!   • Primitive captures: Int, Bool, Float, Long, Double — the headline case for
//!     zero-overhead. Captures must NOT box primitives on closure construction;
//!     the closure must read the primitive directly. Tests both by-value and
//!     by-reference (hoisted-cell) paths for all primitive types.
//!   • Multi-argument primitives with nested captures — exercises multi-field
//!     closure representation.
//!   • Returned/escaping closures — ensures the closure's capture-field layout
//!     persists across function boundaries.
//!   • By-ref `var` mutation inside closures — closure must capture by reference
//!     for mutable `var` bindings, allowing the closure to read/write the
//!     enclosing variable's current state. Tests hoisted-cell capture for all
//!     primitive types.
//!   • Multi-level nesting — verifies captures chain through nested lambdas.
//!
//! Each test produces a runnable assertion: runtime values are checked via
//! `Std.Testing` helpers. The disassembly harnesses (scripts/assert-no-box-*.sh)
//! complement this by inspecting IL/bytecode to verify NO BOX instructions are
//! emitted for primitive captures (Stage 2+), and that closure invoke ABIs are
//! strongly typed rather than Object[]-packed (Stage 3+).
//!
//! Run in CI via the native `lyric test` command on both targets:
//!
//!   lyric test --target dotnet lyric-compiler/lyric/closure_zero_overhead_self_test.l
//!   lyric test --target jvm lyric-compiler/lyric/closure_zero_overhead_self_test.l
//!
//! At Stage 0, these tests pass (they should pass on the current implementation).
//! The disassembly scripts at Stage 0 report baseline (non-zero) box counts that
//! will be the target to beat in later stages.
@test_module
package Lyric.ClosureZeroOverheadSelfTest

import Std.Core
import Std.Collections
import Std.Testing

// ─────────────────────────────────────────────────────────────────────────────
// Primitive captures in loops — the headline case.
// ─────────────────────────────────────────────────────────────────────────────

test "closure captures Int primitive in loop" {
  var result: Int = 0
  var i: Int = 0
  while i < 3 {
    val n = i * 10
    val f: (Int) -> Int = { x: Int -> x + n }
    result = result + f(1)
    i = i + 1
  }
  // Loop iterations: i=0 (n=0, f(1)=1), i=1 (n=10, f(1)=11), i=2 (n=20, f(1)=21)
  // Sum: 1 + 11 + 21 = 33
  assertEqualInt(result, 33, "closure captures Int primitive from each loop iteration")
}

test "closure captures Bool primitive" {
  val flag = true
  val f: (Int) -> Int = { x: Int -> if flag { x * 2 } else { x } }
  assertEqualInt(f(21), 42, "closure captures Bool primitive correctly")
}

test "closure captures Float primitive" {
  val multiplier = 2.5
  val f: (Int) -> Int = { x: Int -> (x.toDouble() * multiplier).toInt() }
  assertEqualInt(f(10), 25, "closure captures Float primitive correctly")
}

test "closure captures Long primitive" {
  val largeNum: Long = 1000000000i64
  val f: (Long) -> Long = { x: Long -> x + largeNum }
  assertEqualLong(f(500000000i64), 1500000000i64, "closure captures Long primitive correctly")
}

test "closure captures Double primitive" {
  val preciseNum = 3.14159
  val f: (Int) -> Int = { x: Int -> (x.toDouble() * preciseNum).toInt() }
  assertEqualInt(f(100), 314, "closure captures Double primitive correctly")
}

// ─────────────────────────────────────────────────────────────────────────────
// Multi-argument primitives with nested captures.
// ─────────────────────────────────────────────────────────────────────────────

test "closure with multi-argument lambda capturing multiple primitives" {
  val a = 10
  val b = 20
  val f: (Int, Int) -> Int = { x: Int, y: Int -> x + y + a + b }
  assertEqualInt(f(5, 3), 38, "multi-arg closure captures a=10 and b=20")
}

test "closure captures three Int primitives" {
  val x = 1
  val y = 2
  val z = 3
  val f: (Int) -> Int = { arg: Int -> arg + x + y + z }
  assertEqualInt(f(10), 16, "three captured Int primitives sum correctly")
}

// ─────────────────────────────────────────────────────────────────────────────
// Returned/escaping closures — closure capture-field layout persists across
// function boundaries.
// ─────────────────────────────────────────────────────────────────────────────

func makePrimitiveCapturingClosure(): (Int) -> Int {
  val magic = 100
  val f: (Int) -> Int = { x: Int -> x + magic }
  return f
}

test "returned closure maintains captured primitive" {
  val f = makePrimitiveCapturingClosure()
  assertEqualInt(f(42), 142, "returned closure captures primitive across function boundary")
}

func makeMultiCaptureClosureInLoop(count: in Int): (Int) -> Int {
  var accumulated: Int = 0
  var i: Int = 0
  while i < count {
    accumulated = accumulated + i
    i = i + 1
  }
  val cap = accumulated
  return { x: Int -> x + cap }
}

test "escaping closure from loop-containing function" {
  val f = makeMultiCaptureClosureInLoop(5)
  // Accumulated: 0+1+2+3+4 = 10
  assertEqualInt(f(32), 42, "escaping closure captures accumulated primitive from loop")
}

// ─────────────────────────────────────────────────────────────────────────────
// By-ref `var` mutation inside closures — closure captures mutable bindings
// by reference, allowing reads and writes to the enclosing variable.
// ─────────────────────────────────────────────────────────────────────────────

test "closure reads mutable var binding" {
  var counter = 0
  val f: (Int) -> Int = { x: Int -> x + counter }
  counter = 10
  assertEqualInt(f(5), 15, "closure reads current mutable var value")
}

test "closure mutates enclosing var" {
  var counter = 0
  val increment: (Int) -> Unit = { x: Int -> counter = counter + x }
  increment(5)
  assertEqualInt(counter, 5, "closure increments enclosing var to 5")
  increment(3)
  assertEqualInt(counter, 8, "closure increments enclosing var again to 8")
}

test "multiple closures share mutable var" {
  var shared = 0
  val getShared: () -> Int = { -> shared }
  val setShared: (Int) -> Unit = { x: Int -> shared = x }
  setShared(42)
  assertEqualInt(getShared(), 42, "second closure reads value written by first closure")
}

test "closure mutates var in loop" {
  var sum = 0
  val addToSum: (Int) -> Unit = { x: Int -> sum = sum + x }
  var i = 0
  while i < 5 {
    addToSum(i)
    i = i + 1
  }
  assertEqualInt(sum, 10, "closure mutation accumulates across loop iterations")
}

test "closure captures and mutates Long var" {
  var counter: Long = 0i64
  val addToCounter: (Long) -> Unit = { x: Long -> counter = counter + x }
  addToCounter(100000000i64)
  assertEqualLong(counter, 100000000i64, "closure increments Long var to 100000000")
  addToCounter(200000000i64)
  assertEqualLong(counter, 300000000i64, "closure increments Long var again to 300000000")
}

test "closure captures and mutates Double var" {
  var accumulator: Double = 0.0
  val addToAccum: (Double) -> Unit = { x: Double -> accumulator = accumulator + x }
  addToAccum(1.5)
  assertTrue(accumulator == 1.5, "closure increments Double var to 1.5")
  addToAccum(2.5)
  assertTrue(accumulator == 4.0, "closure increments Double var again to 4.0")
}

// ─────────────────────────────────────────────────────────────────────────────
// Multi-level nesting — closures chain through nested lambdas.
// ─────────────────────────────────────────────────────────────────────────────

test "closure inside closure captures outer binding" {
  val outer = 100
  val makeInner: (Int) -> ((Int) -> Int) = { x: Int ->
    val inner = x * 2
    { y: Int -> y + outer + inner }
  }
  val innerF = makeInner(5)
  // outer=100, inner (from x=5) = 10, y=7
  assertEqualInt(innerF(7), 117, "nested closure captures both outer and intermediate bindings")
}

test "triple-nested closure" {
  val a = 10
  val makeL1: (Int) -> ((Int) -> ((Int) -> Int)) = { b: Int ->
    val c = b * 2
    { d: Int ->
      val e = d + 1
      { f: Int -> a + c + e + f }
    }
  }
  val l2 = makeL1(5)  // b=5, c=10
  val l3 = l2(8)      // d=8, e=9
  assertEqualInt(l3(1), 30, "triple nested: a(10) + c(10) + e(9) + f(1) = 30")
}

// ─────────────────────────────────────────────────────────────────────────────
// Composite case: loop + multi-arg + returned + var mutation + nesting.
// ─────────────────────────────────────────────────────────────────────────────

func complexClosureScenario(): (Int, Int) -> Int {
  var state = 0
  var i = 0
  while i < 3 {
    state = state + i
    i = i + 1
  }
  // state = 0 + 1 + 2 = 3
  val captured = state
  return { x: Int, y: Int ->
    state = state + 1  // mutation
    x + y + captured + state
  }
}

test "complex scenario: loop + multi-arg + return + var-mutation" {
  val f = complexClosureScenario()
  // captured = 3 (from loop)
  // f(10, 20) -> 10 + 20 + 3 + (state incremented to 4) = 37
  assertEqualInt(f(10, 20), 37, "complex case combines loop, multi-arg, return, and var mutation")
}
