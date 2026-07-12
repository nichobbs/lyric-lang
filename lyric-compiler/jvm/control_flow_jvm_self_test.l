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
//!     `return` and a class-load `VerifyError`).
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
