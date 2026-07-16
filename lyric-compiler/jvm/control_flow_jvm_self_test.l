//! control_flow_jvm_self_test.l — JVM control-flow terminator regression test
//! (#2870, epic #2663).
//!
//! A function/method whose tail `if`/`else` `return`s on both arms (or whose
//! tail `match` `return`s on every arm) is terminating: control never falls off
//! the end, so no implicit trailing `return` must be appended.  The instruction-
//! level `endsWithReturn` check stops at the (unreachable) join label the
//! if/match lowering emits, so it could not see the termination and a stray void
//! `return` was appended after the `if` → the JVM verifier rejected the class
//! (falling-off / type-mismatch on the stray return).  The fix adds an AST-level
//! `blockTerminates` predicate (jvm/codegen/06_items.l) consulted alongside
//! `endsWithReturn` at every function-body return-decision point.
//!
//! Covers, asserting every runtime value on `--target jvm`:
//!   - `return` in BOTH `if`/`else` branches (the #2870 repro), value-returning.
//!   - a nested `if`/`else if`/`else` chain where EVERY arm `return`s.
//!   - a `match` where EVERY arm `return`s.
//!   - a control case proving the implicit-return / fall-off path still works:
//!     a `Unit` fall-off function, and an `if` with NO `else` followed by a
//!     tail-value (the false path falls through to the implicit return).
//!   - #5378: a bare tail-position call to a user-defined `: Never` function
//!     inside a differently-typed function/record-method (`Never` erases to
//!     `JVoid` just like `Unit`, which previously produced a stray void
//!     `return` and a class-load `VerifyError`), in both the block-tail
//!     (`FBBlock`) and `= expr` (`FBExpr`, #5651) function-body forms.
//!   - #2043: a non-void function whose body is a bare `try { … } finally
//!     { … }` (no explicit `return` inside the try) — the try body's tail
//!     VALUE must survive the finally block and become the function's real
//!     return value on both the normal-completion and exceptional paths.
//!     Before the fix (`lowerTryCatchFinallyExpr`, jvm/codegen/05_stmts.l),
//!     `lowerBlockExprInner` fell back to statement-mode lowering for this
//!     shape whenever a `finally` was present, silently discarding the
//!     try's value and returning the declared return type's zero/default
//!     instead — a genuine miscompile (returned 0 instead of 42), not a
//!     VerifyError.
//!   - #5764: the try/catch/finally variant with a `catch` clause present
//!     but not taken (the try body's own value must still win over the
//!     untaken catch arm's).
//!   - #5805: the sibling shape where the join value instead comes from a
//!     MATCHED catch arm (`try { panic } catch E as _ { 7 } finally { … }`) —
//!     the try body's tail is an unconditional `panic`, whose `Never` type
//!     erases to `JVoid` exactly like `Unit`, so the catch-arm value join in
//!     `lowerTryCatchFinallyExpr` (and the sibling `lowerTryCatchExpr`, the
//!     no-`finally` variant) was gated on the TRY BODY's erased-to-`JVoid`
//!     type instead of the catch arm's own (real) produced type, leaving the
//!     caught arm's value on the operand stack when jumping to the join —
//!     `VerifyError: Inconsistent stackmap frames at branch target` at class
//!     load (#5764 flagged this exact path as shipped-untested; this was the
//!     bug the first attempt at testing it found). Both lowering functions now
//!     track the join's effective type separately from the try body's own
//!     type, letting the first value-producing arm (try body OR a matched
//!     catch) establish it.
//!
//! Run by native `lyric test --target jvm`, which compiles this module in-process
//! through the self-hosted `Jvm.Bridge` (`compileToJarBundled`) and runs it under
//! `java`.  Imports only `Std.*`.
@test_module
package Jvm.ControlFlowSelfTest

import Std.Core
import Std.Testing

// #2870 repro: `return` in both `if`/`else` arms, tail position, value-returning.
// Before the fix this compiled to a stray trailing void `return` after the `if`
// and failed JVM verification.
func classify(n: Int): String {
  if n > 0 {
    return "pos"
  } else {
    return "non-pos"
  }
}

// Nested `if` / `else if` / `else` chain where every arm `return`s.  The tail is
// a single `if` whose else-branch is itself an `if`/`else` — `blockTerminates`
// must recurse through the chain and conclude it terminates.
func sign(n: Int): Int {
  if n > 0 {
    return 1
  } else if n < 0 {
    return -1
  } else {
    return 0
  }
}

// A `match` where every arm `return`s: the tail `match` is terminating, so no
// implicit trailing return must be appended.
func describe(n: Int): String {
  match n {
    case 0 -> {
      return "zero"
    }
    case 1 -> {
      return "one"
    }
    case _ -> {
      return "many"
    }
  }
}

// Control: an `if` with both arms returning but reached after a preceding
// statement, so the block's terminator is still the tail `if`.
func absVal(n: Int): Int {
  val doubled = n * 2
  if doubled < 0 {
    return 0 - doubled
  } else {
    return doubled
  }
}

// Control (fall-off path must still work): a `Unit` function whose body falls off
// the end — the implicit `return` IS required here and must still be appended.
func bump(c: in Counter) {
  c.increment()
}

// Control (implicit-tail-value path must still work): an `if` with NO `else`
// followed by a trailing-value expression.  The false path of the `if` falls
// through to the tail `acc` — the function is NOT terminating and the implicit
// return of `acc` must be emitted.
func clampLow(n: Int): Int {
  var acc = n
  if acc < 0 {
    acc = 0
  }
  acc
}

// A Counter to observe the Unit fall-off function ran.
protected type Counter {
  var count: Int
  entry increment() {
    count = count + 1
  }
  entry get(): Int {
    return count
  }
}

// ── #2043: value-producing `try { … } finally { … }`, no explicit `return` ───
// The try body's tail expression (42) must become the function's return
// value; the counter proves the finally block actually ran (once on the
// normal-completion path).
func computeWithFinally(c: in Counter): Int {
  try {
    c.increment()
    42
  } finally {
    c.increment()
  }
}

// Exceptional-path companion: the try body panics before producing a value.
// The finally block must still run (observed via the counter) before the
// panic propagates out of the function — pins the catch-all + rethrow half
// of `lowerTryCatchFinallyExpr`, not just the normal-completion join.
func computeWithFinallyThrows(c: in Counter): Int {
  try {
    c.increment()
    panic("computeWithFinallyThrows: deliberate failure")
  } finally {
    c.increment()
  }
}

// #5764: a `catch` clause is present but never taken (the try body does not
// throw) — the try body's own tail value (1) must still be the join value,
// not the catch arm's (2), and the catch arm's side effect must not run.
// Pins the "value from the try body" path of `lowerTryCatchFinallyExpr`
// specifically in the try/catch/finally (not just try/finally) variant.
func computeWithCatchNotTaken(c: in Counter): Int {
  try {
    c.increment()
    1
  } catch Bug as _ {
    c.increment()
    2
  } finally {
    c.increment()
  }
}

// #5805: the sibling shape where the catch clause IS taken and its own tail
// value must win — the try body's tail is an unconditional `panic`, whose
// `Never` type erases to `JVoid` on the JVM backend (exactly like `Unit`),
// so `lowerTryCatchFinallyExpr` never routed the caught arm's value (7)
// through the join's result slot; it left it on the operand stack when
// jumping to the join label, which every other path (an empty stack)
// disagreed with — `VerifyError: Inconsistent stackmap frames at branch
// target`.  Before the fix this failed at CLASS LOAD, not at runtime.
func computeWithCatchTaken(c: in Counter): Int {
  try {
    c.increment()
    panic("computeWithCatchTaken: deliberate failure")
  } catch Bug as _ {
    c.increment()
    7
  } finally {
    c.increment()
  }
}

// A record with a method whose every arm `return`s — exercises the
// `blockTerminates` check at the `lowerRecordMethod` call-site (#2877).
// Both arms of the inner `if` return unconditionally, so the JVM verifier
// must not see a stray trailing void return.
record Point {
  x: Int
  y: Int
  func quadrant(): String {
    if self.x >= 0 {
      if self.y >= 0 {
        return "Q1"
      } else {
        return "Q4"
      }
    } else {
      if self.y >= 0 {
        return "Q2"
      } else {
        return "Q3"
      }
    }
  }
}

// ── #5378: Never-tail-position call inside a differently-typed function ──────
// `Never` erases to `JVoid` on the JVM backend exactly like `Unit`
// (`Jvm.Codegen.typeExprToJvm`).  A bare tail-position call to a user-defined
// `: Never` function inside a function/method whose own declared return type
// is non-void previously emitted a bare void `return` after the call — a
// class-load `VerifyError: Method expects a return value` (the enclosing
// method's descriptor promises an `Int`/`String`, not nothing).
// `alwaysDiverges` mirrors the issue's `myExit` (a real, unconditionally-
// diverging callee) without actually terminating the test process: it
// records that it ran via `Counter`, then panics — a real, observable
// divergence — instead of calling `System.exit`.
func alwaysDiverges(c: in Counter): Never {
  c.increment()
  panic("alwaysDiverges: unreachable side effect marker")
}

// Free-function shape — the exact #5378 repro: `func myExit(...): Never { … }`
// called bare in tail position inside `func main(): Int { …; myExit(42) }`.
// Exercises the `lowerFunc` fix in `06_items.l`.
func triggerDivergeInt(c: in Counter): Int {
  alwaysDiverges(c)
}

// Record-method shape: the identical gap in `lowerInstanceMethodBody`
// (06_items.l), reached via a record method's tail-position `Never` call.
record Diverger {
  marker: Int
  func triggerDivergeString(c: in Counter): String {
    alwaysDiverges(c)
  }
}

// #5651: the `= expr` (equals-arrow, `FBExpr`) function-body form hits a
// SEPARATE lowering arm from the block-tail (`FBBlock`) form the original
// #5378 fix covered — `emitReturnArrayCoerced`/`coerceArgTo` have no
// `JVoid`->primitive-`toTy` handling, so this shape still crashed
// ("Operand stack underflow") after the #5378 fix landed. Exercises the
// `FBExpr` arms in both `lowerFunc` and `lowerInstanceMethodBody`.
func triggerDivergeIntEq(c: in Counter): Int = alwaysDiverges(c)

record DivergerEq {
  marker: Int
  func triggerDivergeStringEq(c: in Counter): String = alwaysDiverges(c)
}

// ── Tests ─────────────────────────────────────────────────────────────────────
test "return in both if/else branches (the #2870 repro)" {
  assertEqual(classify(5), "pos", "positive input")
  assertEqual(classify(-3), "non-pos", "negative input")
  assertEqual(classify(0), "non-pos", "zero input")
}

test "nested if/else if/else chain where every arm returns" {
  assertEqualInt(sign(7), 1, "positive -> 1")
  assertEqualInt(sign(-7), -1, "negative -> -1")
  assertEqualInt(sign(0), 0, "zero -> 0")
}

test "match where every arm returns" {
  assertEqual(describe(0), "zero", "0 -> zero")
  assertEqual(describe(1), "one", "1 -> one")
  assertEqual(describe(42), "many", "42 -> many")
}

test "if/else after a preceding statement, both arms return" {
  assertEqualInt(absVal(3), 6, "positive doubled")
  assertEqualInt(absVal(-4), 8, "negative doubled, negated")
}

test "Unit fall-off function still emits its implicit return" {
  val c = Counter(count = 0)
  bump(c)
  bump(c)
  assertEqualInt(c.get(), 2, "fall-off Unit function ran twice")
}

test "if without else followed by a tail value still falls through" {
  assertEqualInt(clampLow(5), 5, "non-negative passes through")
  assertEqualInt(clampLow(-9), 0, "negative clamped to 0")
}

test "record method with all-terminating if/else arms (blockTerminates at lowerRecordMethod)" {
  val p1 = Point(x = 1, y = 1)
  val p2 = Point(x = -1, y = 1)
  val p3 = Point(x = -1, y = -1)
  val p4 = Point(x = 1, y = -1)
  assertEqual(p1.quadrant(), "Q1", "Q1: (+, +)")
  assertEqual(p2.quadrant(), "Q2", "Q2: (-, +)")
  assertEqual(p3.quadrant(), "Q3", "Q3: (-, -)")
  assertEqual(p4.quadrant(), "Q4", "Q4: (+, -)")
}

test "#5378: bare tail-position call to a `: Never` free function inside a non-void function" {
  val c = Counter(count = 0)
  var caught = false
  try {
    triggerDivergeInt(c)
  } catch Bug as _ {
    caught = true
  }
  assertTrue(caught, "alwaysDiverges' panic must propagate out of triggerDivergeInt")
  assertEqualInt(c.get(), 1, "alwaysDiverges' side effect (increment) ran before it diverged")
}

test "#5378: bare tail-position call to a `: Never` function inside a non-void record method" {
  val c = Counter(count = 0)
  val d = Diverger(marker = 0)
  var caught = false
  try {
    d.triggerDivergeString(c)
  } catch Bug as _ {
    caught = true
  }
  assertTrue(caught, "alwaysDiverges' panic must propagate out of the record method too")
  assertEqualInt(c.get(), 1, "side effect ran exactly once")
}

test "#5651: `= expr` (FBExpr) body form of a Never-tail free function" {
  val c = Counter(count = 0)
  var caught = false
  try {
    triggerDivergeIntEq(c)
  } catch Bug as _ {
    caught = true
  }
  assertTrue(caught, "alwaysDiverges' panic must propagate out of an `= expr` body")
  assertEqualInt(c.get(), 1, "alwaysDiverges' side effect ran before it diverged")
}

test "#5651: `= expr` (FBExpr) body form of a Never-tail record method" {
  val c = Counter(count = 0)
  val d = DivergerEq(marker = 0)
  var caught = false
  try {
    d.triggerDivergeStringEq(c)
  } catch Bug as _ {
    caught = true
  }
  assertTrue(caught, "alwaysDiverges' panic must propagate out of an `= expr` record method")
  assertEqualInt(c.get(), 1, "side effect ran exactly once")
}

test "#2043: non-void function body is a bare try/finally — the try's tail value survives the finally" {
  val c = Counter(count = 0)
  val result = computeWithFinally(c)
  assertEqualInt(
    result,
    42,
    "the try body's tail value (42) must be the function's return value, not retTy's zero/default"
  )
  assertEqualInt(c.get(), 2, "both the try body and the finally block ran exactly once each")
}

test "#2043: non-void try/finally still runs the finally block and propagates a panic from the try body" {
  val c = Counter(count = 0)
  var caught = false
  try {
    computeWithFinallyThrows(c)
  } catch Bug as _ {
    caught = true
  }
  assertTrue(caught, "the panic inside the try body must still propagate out of the function")
  assertEqualInt(c.get(), 2, "the finally block ran (via the catch-all handler) before the panic propagated")
}

test "#5764: try body's value survives finally when a catch clause is present but not taken" {
  val c = Counter(count = 0)
  val result = computeWithCatchNotTaken(c)
  assertEqualInt(
    result,
    1,
    "the try body's tail value (1) must be the join value; the untaken catch arm's value (2) must not win"
  )
  assertEqualInt(c.get(), 2, "the try body and the finally block each ran once; the catch arm did not run")
}

test "#5805: try body's value join with finally, matched catch arm's value wins" {
  val c = Counter(count = 0)
  val result = computeWithCatchTaken(c)
  assertEqualInt(
    result,
    7,
    "the matched catch arm's tail value (7) must be the join value, even though the try body's own tail " +
      "(an unconditional panic) never reaches the join"
  )
  assertEqualInt(c.get(), 3, "the try body, the catch arm, and the finally block each ran once")
}
