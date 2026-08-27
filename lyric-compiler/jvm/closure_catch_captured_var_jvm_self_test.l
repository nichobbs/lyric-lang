//! closure_catch_captured_var_jvm_self_test.l — JVM regression test for #6551:
//! a closure body shaped `try { … } catch Bug as b { <captured var> = … }` —
//! a captured `var` assigned directly inside a `catch` arm, itself inside a
//! closure literal — failed class verification at load time with `VerifyError:
//! Operand stack overflow`.
//!
//! Root cause (`jvm/lowering.l` / `jvm/bytecode.l`): `lowerInsn`'s `LLabel`
//! case reset the tracked operand-stack depth to 0 at EVERY label, including
//! an exception-handler entry label.  JVMS §4.10.1.6 has the JVM implicitly
//! push the caught exception reference onto the stack when control transfers
//! to a handler, so a handler body actually starts at depth 1, not 0.  The
//! `maxStack`-inference pass (`asm.peakStack`, used verbatim for a closure's
//! synthesised `invoke` method — `lowerClosureMethod` passes `maxStack = 0`,
//! unlike a top-level `func`'s padded floor of 16) therefore under-counted
//! the true peak stack depth by exactly one slot for any catch-arm body that
//! reached that peak — such as a hoisted-cell `var` mutation, which pushes
//! the cell array reference, index, and new value before `aastore`.  Fixed
//! by seeding `MethodAssembler.handlerLabels` (a label -> catch-class map,
//! `Jvm.Lowering.collectHandlerLabels`) before a lowering pass so `LLabel`
//! resets a handler-entry label's depth to 1 (`resetStackToHandlerEntry`,
//! `jvm/bytecode.l`) instead of 0.
//!
//! Every case below is a `Unit`-typed closure literal bound to a `val` and
//! immediately invoked, capturing an outer `var` that a `catch Bug` arm
//! mutates directly (no `AtomicBoolean`/`AtomicReference` workaround) — the
//! exact shape that failed to class-verify. Each asserts the real runtime
//! value on BOTH the no-throw and throwing paths, not just "doesn't crash".
//!
//! Run by native `lyric test --target jvm`, which compiles this module
//! in-process through the self-hosted `Jvm.Bridge` (`compileToJarBundled`)
//! and runs it under `java`. Imports only `Std.*`.
@test_module
package Jvm.ClosureCatchCapturedVarSelfTest

import Std.Core
import Std.Testing

// The exact #6551 repro shape: a single captured `Bool` var, mutated directly
// (not via an Atomic* wrapper) inside a `catch Bug` arm of a closure literal.
func runBoolFlag(shouldThrow: Bool): Bool {
  var faulted = false
  val wrapped: () -> Unit = { ->
    try {
      if shouldThrow {
        panic("boom")
      }
      println("hi")
    } catch Bug as b {
      faulted = true
    };
    ()
  }
  wrapped()
  faulted
}

// Same shape with an `Int` captured var, pinning the `istore` variant of the
// hoisted-cell write inside the catch arm (`runBoolFlag` above exercises
// the `Bool`, i.e. int-typed-slot, form already, but through a literal
// `true`; this assigns a computed value instead).
func runIntCounter(shouldThrow: Bool): Int {
  var counter = 0
  val wrapped: () -> Unit = { ->
    try {
      if shouldThrow {
        panic("boom")
      }
      counter = 1
    } catch Bug as b {
      counter = 99
    };
    ()
  }
  wrapped()
  counter
}

// A `String` captured var assigned from the bound exception's own message —
// pushes the hoisted-cell array reference, index, AND the `b.message` read
// (itself a field access on the caught exception) before the `aastore`,
// reaching a deeper peak than a literal-valued assignment.
func runLastError(shouldThrow: Bool): String {
  var lastError = "none"
  val wrapped: () -> Unit = { ->
    try {
      if shouldThrow {
        panic("kaboom")
      }
    } catch Bug as b {
      lastError = b.message
    };
    ()
  }
  wrapped()
  lastError
}

// TWO captured vars mutated in the same catch arm — two separate hoisted
// cells, each needing its own array-ref/index/value push sequence back to
// back, before the closure body's own trailing `()`.
func runTwoFlags(shouldThrow: Bool): Int {
  var a = 0
  var b = 0
  val wrapped: () -> Unit = { -> try { if shouldThrow { panic("multi") } } catch Bug as e { a = 1; b = 2 }; () }
  wrapped()
  a + b
}

// ── Tests ─────────────────────────────────────────────────────────────────────
test "closure: captured Bool var assigned in a catch arm — no throw leaves it unset" {
  assertFalse(runBoolFlag(false), "no throw -> catch arm never runs -> faulted stays false")
}

test "closure: captured Bool var assigned in a catch arm — a thrown panic sets it" {
  assertTrue(runBoolFlag(true), "panic inside try -> catch arm runs -> faulted set to true")
}

test "closure: captured Int var assigned in a catch arm on both paths" {
  assertEqualInt(runIntCounter(false), 1, "no throw -> try body runs -> counter = 1")
  assertEqualInt(runIntCounter(true), 99, "panic -> catch arm runs -> counter = 99")
}

test "closure: captured String var assigned from the bound exception's message" {
  assertEqual(runLastError(false), "none", "no throw -> lastError stays at its initial value")
  assertEqual(runLastError(true), "kaboom", "panic('kaboom') -> lastError = caught exception's message")
}

test "closure: two captured vars assigned in the same catch arm" {
  assertEqualInt(runTwoFlags(false), 0, "no throw -> neither var is assigned -> sum is 0")
  assertEqualInt(runTwoFlags(true), 3, "panic -> both vars assigned (1 + 2) -> sum is 3")
}
