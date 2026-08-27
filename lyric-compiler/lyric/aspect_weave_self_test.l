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

// ─────────────────────────────────────────────────────────────────────────────
// #6416: a same-file `alias` referenced inside an aspect's `around` advice
// body must resolve exactly like it would in an ordinary function body.
// Before the fix, `Lyric.TypeAliasResolve.resolveItem` passed `IAspect`
// through unchanged, so `Meters` below reached the weaver/codegen still
// spelled as the literal name "Meters" — on `--target jvm` this crashed at
// class-verification time (`VerifyError: Bad type on operand stack`, since
// bytecode built for a nonexistent user class "Meters" was emitted where a
// primitive `long` was expected), verified live against the pre-fix
// compiler. This test proves the resolved value participates correctly in
// real arithmetic on both targets (not merely "doesn't crash").
// ─────────────────────────────────────────────────────────────────────────────
alias Meters = Long

aspect AddBonus {
  matches: name in { addBonus }
  around(call) -> ret {
    val bonus: Meters = 10i64
    ret = proceed() + bonus
  }
}

func addBonus(): Long {
  1i64
}

test "same-file alias inside aspect advice body resolves and participates in arithmetic (#6416)" {
  assertEqualLong(addBonus(), 11i64, "proceed() + Meters-typed local: 1 + 10 = 11")
}

// ─────────────────────────────────────────────────────────────────────────────
// #5182: a statement AFTER a BARE, non-capturing `proceed(args)` (as opposed
// to #3402's `ret = proceed()` capturing form) produced `InvalidProgramException`
// when the matched target's return type is not `Unit` — exactly the shape
// `examples/agent/config-and-aspects.l`'s `RequestLogging`/`Auth` aspects use
// (`Std.Log.info(...); proceed(args); Std.Log.info(...)`).  Before the fix, the
// weaver's naive statement splice left `proceed(args)`'s call result discarded
// (bare `SExpr`, non-tail position) and the elaborated wrapper body's actual
// trailing statement was the println AFTER it — `Unit`-typed — while the
// wrapper is declared to return the target's real type, so it fell off a
// non-void method with no return value.  The fix auto-lifts EVERY bare
// (non-capturing) `proceed(args)` statement — trailing or not, at any
// nesting depth — into `ret = proceed(args)` whenever the target returns a
// real value, so the synthesised `var ret; ...; return ret` wrapping
// (#3402) kicks in exactly as it does for the explicit `ret =
// proceed(args)` form.  (A first version of this fix gated the lift on
// "not the last statement of its immediate enclosing block," which a
// review round (#6624) found still missed a bare `proceed(args)` in tail
// position of a NESTED `if`/`while`/`try` body one level deeper than the
// advice's own top-level statement list — the lift is unconditional now,
// including the "expression-style advice" case a few tests above, which
// still returns the identical value via the `var ret`/`return ret` route
// instead of implicit fall-through.)  Bisected in the issue as independent
// of the `matches:` wildcard vs. exact pattern; reproduces identically on
// `--target dotnet` and `--target jvm` (this same file runs on both,
// mirroring every other case above), so both are fixed by the one
// weaver-level change.
// ─────────────────────────────────────────────────────────────────────────────
aspect RequestLoggingLike {
  matches: name in { handleGreet }
  around(args) -> ret {
    println("enter")
    proceed(args)
    println("exit")
  }
}

func handleGreet(name: in String): String {
  "hello, " + name
}

test "statement after non-capturing proceed(args) on a non-Unit target runs cleanly (#5182)" {
  assertTrue(
    handleGreet("world") == "hello, world",
    "handleGreet(\"world\") threads proceed(args)'s result through a trailing statement without InvalidProgramException"
  )
}

// A second matched function proves the auto-lift isn't a one-shot / single-
// call-site fluke — both `handleGreet` and `handleFarewell` route through the
// SAME advice body, each getting its own woven wrapper.
func handleFarewell(name: in String): String {
  "farewell, " + name
}

aspect RequestLoggingLike2 {
  matches: name in { handleFarewell }
  around(args) -> ret {
    println("enter")
    proceed(args)
    println("exit")
  }
}

test "statement after non-capturing proceed(args), second matched function (#5182)" {
  assertTrue(handleFarewell("world") == "farewell, world", "handleFarewell(\"world\") via the same advice shape")
}

// ─────────────────────────────────────────────────────────────────────────────
// #6624 (review finding on the first #5182 fix): a bare, non-capturing
// `proceed(args)` in TAIL POSITION OF A NESTED `if`-branch — but NOT the
// advice body's own top-level last statement — reproduced the identical
// InvalidProgramException the flat-statement cases above already cover.
// The first fix version gated the auto-lift on "not last in this
// statement's IMMEDIATE enclosing block", computed independently per
// nested `rewriteBlock` call — so `proceed(args)` being the if-branch's
// own last statement read as `isLast == true` there, even though the
// if-statement itself is NOT the advice body's last statement (a
// `println` follows it). The fix is now unconditional: every bare
// `proceed(args)`, regardless of nesting, lifts into `ret = proceed(args)`.
// Both branches of the guard are exercised so both control-flow paths
// (proceeds vs. skips) are proven to still return the correct value.
// ─────────────────────────────────────────────────────────────────────────────
aspect NestedIfProceed {
  matches: name in { annotate }
  around(args) -> ret {
    if true {
      proceed(args)
    }
    println("after nested if")
  }
}

func annotate(x: in Int): Int {
  x * 3
}

test "bare proceed(args) as the tail statement of a NESTED if-branch, followed by more advice statements (#6624)" {
  assertTrue(
    annotate(7) == 21,
    "annotate(7): nested-if proceed(args) result threads through the advice's own trailing statement"
  )
}

// The unconditional fix recurses through `rewriteBlock` uniformly for every
// block-bearing statement kind, so the `if`-branch case above is not
// special — but per review on PR #6621, verified rather than inferred for
// `while` and `try` too (the same generic recursion, exercised concretely).
aspect NestedWhileProceed {
  matches: name in { annotateWhile }
  around(args) -> ret {
    var i = 0
    while i < 1 {
      i = i + 1
      proceed(args)
    }
    println("after nested while")
  }
}

func annotateWhile(x: in Int): Int {
  x * 5
}

test "bare proceed(args) as the tail statement of a NESTED while-loop body, followed by more advice statements (#6624)" {
  assertTrue(
    annotateWhile(4) == 20,
    "annotateWhile(4): nested-while proceed(args) result threads through the advice's own trailing statement"
  )
}

aspect NestedTryProceed {
  matches: name in { annotateTry }
  around(args) -> ret {
    try {
      proceed(args)
    } catch Bug {
    }
    println("after nested try")
  }
}

func annotateTry(x: in Int): Int {
  x * 7
}

test "bare proceed(args) as the tail statement of a NESTED try-block, followed by more advice statements (#6624)" {
  assertTrue(
    annotateTry(3) == 21,
    "annotateTry(3): nested-try proceed(args) result threads through the advice's own trailing statement"
  )
}
