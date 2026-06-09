//! closure_correctness_self_test.l — regression tests for two CRITICAL closure
//! correctness fixes:
//!
//!   1. Multi-level nested closure capture (#1479): a lambda inside a lambda
//!      can now read names captured by the outer lambda.  Previously the inner
//!      lambda's `lambdaCaptureNamesMsil` only inspected `fctx.slots` (the
//!      enclosing lambda's *own* locals) and silently ignored names that were
//!      accessible only via `fctx.captureNameToIndex` (the outer lambda's own
//!      captured set).  This led to silent wrong-value reads or runtime panics.
//!
//!   2. Lambdas in @test_module bodies (#1854): `assertPanics` / `assertPanicsWith`
//!      receive a `() -> Unit` lambda.  The self-hosted MSIL emitter was calling
//!      `assertPanics(String, Object)` but the F#-built `Std.Testing` DLL declares
//!      `assertPanics(String, System.Action)`.  The fix corrects
//!      `typeExprToMsilCtx` to map `TFunction([], TUnit)` → `MClass("System.Action")`
//!      so the MemberRef signature matches the F#-compiled method.
//!
//! Run with:
//!   lyric test lyric-compiler/lyric/closure_correctness_self_test.l
//!
//! Compiles through the self-hosted `Msil.Bridge`; no F# shim needed.
//! Imports only `Std.*`.
@test_module
package ClosureCorrectnessTest

import Std.Core
import Std.Testing

// ─── #1479 multi-level closure capture ──────────────────────────────────────

test "two-level immutable capture" {
  val x = 42
  val outer = { ->
    val inner = { -> x }
    inner()
  }
  assertEqualInt(outer(), 42, "two-level immutable capture")
}

test "three-level immutable capture" {
  val y = 100
  val f1 = { ->
    val f2 = { ->
      val f3 = { -> y }
      f3()
    }
    f2()
  }
  assertEqualInt(f1(), 100, "three-level immutable capture")
}

test "inner closure uses outer closure captured name twice" {
  val base = 7
  val adder = { ->
    val doubler = { -> base + base }
    doubler()
  }
  assertEqualInt(adder(), 14, "captured name used twice in inner body")
}

test "nested closure captures mutable (cell) from outer scope" {
  var counter = 0
  val inc = { ->
    val check = { -> counter }
    counter = counter + 1
    check()
  }
  val afterFirst = inc()
  val _ = inc()
  assertEqualInt(afterFirst, 1, "mutable cell: value after first increment")
  assertEqualInt(counter, 2, "mutable cell: outer counter updated")
}

test "multiple distinct captured values at two levels" {
  val a = 3
  val b = 5
  val outer = { ->
    val inner = { -> a + b }
    inner()
  }
  assertEqualInt(outer(), 8, "two distinct captured values")
}

// ─── #1854 lambdas in @test_module (#1877 uniform ABI) ──────────────────────

test "assertPanics compiles and runs in test_module" {
  assertPanics("explicit panic", { -> panic("expected") })
}

test "assertPanicsWith compiles and runs in test_module" {
  assertPanicsWith("panic with substring", "expected", { -> panic("expected panic message") })
}

test "assertPanics fails when fn does not panic" {
  val didFail = try {
    assertPanics("should fail", { -> () })
    false
  } catch Bug as _ {
    true
  }
  assertTrue(didFail, "assertPanics should itself panic when fn is normal")
}
