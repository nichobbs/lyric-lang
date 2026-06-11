//! propagate_self_test.l — #1475 (Band 2): the `?` error-propagation operator.
//!
//! Exercises the self-hosted `Lyric.Propagate` lowering end-to-end: each `?`
//! is rewritten into a match-unwrap + early-return of the wrapped Err/None,
//! keyed off the enclosing function's declared return type.  Before this pass
//! shipped, `EPropagate` was a codegen no-op (`x?` compiled as `x`) — a silent
//! miscompile of every program using `?`.
//!
//! Run in CI via native `lyric test --target dotnet`, which compiles this
//! module in-process through the self-hosted `Msil.Bridge` (so the `?`
//! lowering under test is the one that runs).  The F0020 error-path tests
//! import `Lyric.Parser` and `Lyric.Propagate` from the stage-1 DLL bundle
//! (resolved as restored deps via #2364, same mechanism as weaver_self_test.l).
//! MSIL target only; JVM-target `?` parity is tracked separately (epic #1470).
@test_module
package Lyric.PropagateSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Lyric.Lexer
import Lyric.Parser
import Lyric.Propagate

// A Result-producing helper whose Err carries a distinguishing label, so the
// tests can prove WHICH `?` short-circuited (i.e. evaluation order).
func okIf(cond: in Bool, v: in Int, label: in String): Result[Int, String] {
  if cond {
    Ok(v)
  } else {
    Err(label)
  }
}

// Two `?` in sequence in a Result-returning function.  On the first Err the
// function must return immediately, never evaluating the second operand.
func chain(a: in Int, b: in Int): Result[Int, String] {
  val x = okIf(a > 0, a, "a")?
  val y = okIf(b > 0, b, "b")?
  Ok(x + y)
}

func resultLabel(r: in Result[Int, String]): String {
  match r {
    case Ok(_) -> "ok"
    case Err(e) -> e
  }
}

func resultValue(r: in Result[Int, String]): Int {
  match r {
    case Ok(v) -> v
    case Err(_) -> -1
  }
}

test "Result `?`: all-Ok unwraps and continues" {
  assertEqualInt(resultValue(chain(3, 4)), 7, "3 + 4 = 7")
  assertEqual(resultLabel(chain(3, 4)), "ok", "no early return")
}

test "Result `?`: first failure short-circuits before the second is evaluated" {
  // a <= 0 -> first `?` returns Err(\"a\"); the second okIf must not run.
  assertEqual(resultLabel(chain(-1, -2)), "a", "first ? wins")
}

test "Result `?`: second failure propagates after the first succeeds" {
  assertEqual(resultLabel(chain(3, -2)), "b", "second ? propagates")
}

// `?` in a non-tail / nested position: inside the argument of `Ok(...)` and an
// arithmetic expression.
func nested(a: in Int): Result[Int, String] {
  Ok(okIf(a > 0, a, "n")? + 1)
}

test "Result `?`: nested non-tail position unwraps then continues" {
  assertEqualInt(resultValue(nested(5)), 6, "5 + 1 = 6")
  assertEqual(resultLabel(nested(-1)), "n", "nested ? early-returns Err")
}

// ── Option propagation ───────────────────────────────────────────────────────
func optDiv(n: in Int, d: in Int): Option[Int] {
  if d == 0 {
    None
  } else {
    Some(n / d)
  }
}

func compute(a: in Int, b: in Int): Option[Int] {
  val x = optDiv(100, a)?
  val y = optDiv(100, b)?
  Some(x + y)
}

func optTag(o: in Option[Int]): Int {
  match o {
    case None -> -1
    case Some(v) -> v
  }
}

test "Option `?`: all-Some unwraps and continues" {
  assertEqualInt(optTag(compute(2, 4)), 75, "50 + 25 = 75")
}

test "Option `?`: a None short-circuits to None" {
  assertEqualInt(optTag(compute(0, 4)), -1, "first ? -> None")
  assertEqualInt(optTag(compute(2, 0)), -1, "second ? -> None")
}

// ── `?` inside nested statement forms (if branch, while body) ─────────────────
// Exercises the rewriter's recursion through `if` / `while` bodies, and the
// early-return from inside a loop.
func condProp(useA: in Bool, a: in Int, b: in Int): Result[Int, String] {
  if useA {
    val x = okIf(a > 0, a, "a")?
    Ok(x)
  } else {
    val y = okIf(b > 0, b, "b")?
    Ok(y)
  }
}

test "Result `?` inside both arms of an if" {
  assertEqualInt(resultValue(condProp(true, 5, 9)), 5, "then-arm Ok")
  assertEqualInt(resultValue(condProp(false, 5, 9)), 9, "else-arm Ok")
  assertEqual(resultLabel(condProp(true, -1, 9)), "a", "then-arm ? Err")
  assertEqual(resultLabel(condProp(false, 5, -9)), "b", "else-arm ? Err")
}

// `?` inside a while-loop body: a negative element early-returns Err mid-loop.
// (The earlier "loop early-return dropped" symptom was actually #1779 bug A —
// a `List[Int]` element comparison miscompiling; with that fixed, `?` over a
// value-type list inside a loop works.)
func sumPositives(xs: in List[Int]): Result[Int, String] {
  var total = 0
  var i = 0
  while i < xs.count {
    val v = okIf(xs[i] > 0, xs[i], "neg")?
    total = total + v
    i = i + 1
  }
  Ok(total)
}

test "Result `?` inside a while-loop body early-returns mid-iteration" {
  val all: List[Int] = newList()
  all.add(1)
  all.add(2)
  all.add(3)
  assertEqualInt(resultValue(sumPositives(all)), 6, "1+2+3 = 6")

  val mixed: List[Int] = newList()
  mixed.add(1)
  mixed.add(-2)
  mixed.add(3)
  assertEqual(resultLabel(sumPositives(mixed)), "neg", "negative element ? -> Err")
}

// NOTE: `?` inside an impl/interface method body now runs correctly — what
// blocked it was #1784 (a value-type *parameter* on an interface/impl method
// faulted the JIT, unrelated to `?`), fixed separately.  End-to-end coverage of
// `?` in an impl method lives in `impl_method_self_test.l`.
// ── F0020 error-path tests (#1781, #1801) ─────────────────────────────────────
// These exercise `lowerPropagateFile` directly against source strings that
// contain invalid `?` usage.  The diagnostic path was previously untested;
// regressions that silently removed F0020 and reverted to pass-through would not
// have been caught by the runtime tests above.
func propHasDiag(diags: in List[Diagnostic], code: in String): Bool {
  var i = 0
  var found = false
  while i < diags.count {
    if diags[i].code == code {
      found = true
    }
    i = i + 1
  }
  found
}

test "F0020: ? in non-Result/Option function emits diagnostic" {
  // The enclosing function returns `Int`, not `Result` or `Option`.
  // `lowerPropagateFile` must emit F0020 rather than silently pass through.
  val src = "package P\nfunc f(x: in Int): Int {\n  val r: Result[Int, String] = Ok(1)\n  r?\n}\n"
  val result = lowerPropagateFile(parse(src).file)
  assertTrue(propHasDiag(result.diagnostics, "F0020"), "F0020 emitted for ? in Int function")
}

test "F0020: ? inside a lambda body emits lambda-specific diagnostic" {
  // `?` inside a lambda body — the lambda's return monad is unknown to
  // the propagation pass (PropInLambda), so the lambda-specific F0020
  // message fires regardless of whether the enclosing function returns Result.
  // (#1801)
  val src = "package P\nfunc f(): Result[Int, String] {\n  val fn = \\() -> {\n    val r: Result[Int, String] = Ok(1)\n    r?\n  }\n  Ok(1)\n}\n"
  val result = lowerPropagateFile(parse(src).file)
  assertTrue(propHasDiag(result.diagnostics, "F0020"), "F0020 emitted for ? inside lambda in Result function")
}

test "F0020: ? inside a lambda nested in a non-Result function also emits" {
  // PropInLambda fires even when the outer function's return type is neither
  // Result nor Option — the lambda wrapper is detected first. (#1801)
  val src = "package P\nfunc f(): Unit {\n  val fn = \\() -> {\n    val r: Result[Int, String] = Ok(1)\n    r?\n  }\n}\n"
  val result = lowerPropagateFile(parse(src).file)
  assertTrue(propHasDiag(result.diagnostics, "F0020"), "F0020 emitted for ? inside lambda in Unit function")
}
