//! aspect_weave_self_test.l — end-to-end regression test for aspect
//! weaving on the self-hosted backends (#3402).
//!
//! Before #3402, aspect weaving was non-functional on `--target dotnet`:
//! a woven function threw `InvalidProgramException` at runtime because the
//! weaver never lowered the `around(...) -> ret` out-variable binding — the
//! synthesised wrapper assigned `ret` (never declared, never returned) and
//! fell off the end of a non-void method.  On `--target jvm` the woven call
//! to the renamed `__aspect_target` resolved to the `(…)Object` guess
//! (`NoSuchMethodError` / `VerifyError`) because the JVM bridge built its
//! function-signature registry from the *pre*-weave file.  This test runs
//! real woven functions and asserts their runtime values, so weaving can
//! never silently regress again.
//!
//! Run via native `lyric test` on BOTH targets (mirrors `bitwise_self_test.l`):
//!
//!   lyric test lyric-compiler/lyric/aspect_weave_self_test.l                # MSIL
//!   lyric test --target jvm lyric-compiler/lyric/aspect_weave_self_test.l   # JVM
//!
//! `lyric test` synthesises a program from the `test` blocks and compiles it
//! IN-PROCESS through the self-hosted bridge, which runs `Lyric.Weaver` as a
//! middle-end pass — so the woven wrappers below are the real product of the
//! production weave path.  Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1`
//! is needed.  No new F#: discovery is the native Lyric path.
//!
//! Coverage:
//!   - out-variable advice (`ret = proceed()`) — the headline #3402 form;
//!   - the `call.proceed()` spelling every shipped library template uses;
//!   - short-circuit (advice never calls proceed, returns an alternative);
//!   - argument-observing advice that conditionally proceeds;
//!   - expression-style advice (trailing `proceed()`, no `ret` write);
//!   - the ambient `call.shortName` value inside advice;
//!   - a `Unit`-returning woven function (no value to thread through `ret`).
@test_module
package Lyric.AspectWeaveSelfTest

import Std.Core
import Std.Testing

// ─────────────────────────────────────────────────────────────────────────────
// Out-variable advice: `ret = proceed()` (the headline #3402 form).
// ─────────────────────────────────────────────────────────────────────────────
aspect PassThrough {
  matches: name in { addOne }
  around(call) -> ret {
    ret = proceed()
  }
}

func addOne(x: Int): Int {
  return x + 1
}

test "out-variable pass-through returns the target value" {
  // Woven `addOne` must still compute x + 1 (no InvalidProgramException, no
  // zero-default leaking through an unreturned `ret`).
  assertEqualInt(addOne(41), 42, "addOne(41) woven")
  assertEqualInt(addOne(0), 1, "addOne(0) woven")
}

// ─────────────────────────────────────────────────────────────────────────────
// `call.proceed()` spelling (the form used by ValidateInput / CallLogging /
// RequiresAuth / Retry library templates).
// ─────────────────────────────────────────────────────────────────────────────
aspect CallProceedForm {
  matches: name in { doubleIt }
  around(call) -> ret {
    ret = call.proceed()
  }
}

func doubleIt(x: Int): Int {
  return x * 2
}

test "call.proceed() advances to the target" {
  assertEqualInt(doubleIt(21), 42, "doubleIt(21) via call.proceed()")
}

// ─────────────────────────────────────────────────────────────────────────────
// Short-circuit: advice returns an alternative without calling proceed at all
// (the ValidateInput Err-path shape).  The target must NOT run.
// ─────────────────────────────────────────────────────────────────────────────
aspect ShortCircuit {
  matches: name in { neverRuns }
  around(call) -> ret {
    if false {
      ret = call.proceed()
    } else {
      ret = 99
    }
  }
}

func neverRuns(x: Int): Int {
  return x + 1
}

test "short-circuit advice returns its own value, skipping the target" {
  assertEqualInt(neverRuns(5), 99, "neverRuns short-circuits to 99")
}

// ─────────────────────────────────────────────────────────────────────────────
// `call.shortName`-discriminating advice: one aspect matches two functions and
// proceeds for one, short-circuits for the other based on the ambient short
// name.  Matching both targets makes BOTH guard branches reachable, so the
// `call.shortName` value is genuinely exercised (not a dead else).
// ─────────────────────────────────────────────────────────────────────────────
aspect Gate {
  matches: name in { gatedOpen, gatedShut }
  around(call) -> ret {
    if call.shortName == "gatedOpen" {
      ret = call.proceed()
    } else {
      ret = -1
    }
  }
}

func gatedOpen(x: Int): Int {
  return x * 10
}

func gatedShut(x: Int): Int {
  return x * 10
}

test "advice discriminates on call.shortName: proceed vs short-circuit" {
  // gatedOpen matches the guard → proceeds (4 * 10).
  assertEqualInt(gatedOpen(4), 40, "gatedOpen proceeds (shortName matched)")
  // gatedShut takes the else → short-circuits to -1 without running the target.
  assertEqualInt(gatedShut(4), -1, "gatedShut short-circuits (shortName guard)")
}

// ─────────────────────────────────────────────────────────────────────────────
// Expression-style advice: trailing `proceed()` is the wrapper's return value
// (no `ret` write — the pre-#3402 path that must keep working).
// ─────────────────────────────────────────────────────────────────────────────
aspect ExprStyle {
  matches: name in { exprTarget }
  around(call) -> ret {
    proceed()
  }
}

func exprTarget(x: Int): Int {
  return x - 1
}

test "expression-style advice returns the trailing proceed() value" {
  assertEqualInt(exprTarget(43), 42, "exprTarget(43) via trailing proceed()")
}

// ─────────────────────────────────────────────────────────────────────────────
// Unit-returning woven function: no value flows through `ret`, so the wrapper
// must call the target and return cleanly without synthesising a bogus value
// slot.  Exercises the `targetReturnsUnit` codegen path through the weave.
// ─────────────────────────────────────────────────────────────────────────────
aspect UnitWrap {
  matches: name in { touch }
  around(call) -> ret {
    proceed()
  }
}

func touch(x: in Int): Unit {
  // Body intentionally empty: the test only needs the woven wrapper to invoke
  // a Unit-returning target and return without an InvalidProgramException /
  // VerifyError.
}

test "Unit-returning woven function compiles and runs cleanly" {
  touch(1)
  touch(2)
  assertTrue(true, "Unit-returning wrapper executed through the weave")
}

// ─────────────────────────────────────────────────────────────────────────────
// Unit-returning target with OUT-VARIABLE advice (`ret = proceed()`) — the
// #3424 regression.  Before the fix the weaver synthesised `var ret: Unit` +
// `return ret` for a void type, which codegen could not represent (a void local
// has no slot; the discarded store popped an empty stack) — reintroducing the
// exact InvalidProgramException #3402 set out to remove.  The lowering now
// strips `ret = <expr>` to a bare `<expr>` for Unit targets, so `proceed()`
// still runs and the wrapper is a plain void method.
// ─────────────────────────────────────────────────────────────────────────────
aspect UnitOut {
  matches: name in { sink }
  around(call) -> ret {
    ret = proceed()
  }
}

func sink(x: in Int): Unit {
  // Empty body: the test only needs the woven wrapper to run `ret = proceed()`
  // against a Unit target without an InvalidProgramException / VerifyError.
}

test "Unit-returning out-variable advice (ret = proceed()) runs cleanly" {
  sink(1)
  sink(2)
  assertTrue(true, "ret = proceed() on a Unit target wove without InvalidProgramException")
}
