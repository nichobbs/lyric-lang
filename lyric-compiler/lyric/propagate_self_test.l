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
// ── Async implicit-await propagation (#6920) ──────────────────────────────────
// `expr?` where `expr` is DIRECTLY a call to an `async func` — no literal
// `await` — used to desugar `?` straight to `match expr { ... }`, leaving the
// async kickoff's raw `Task<Result[T,E]>` as the scrutinee instead of the
// awaited `Result[T,E]`: the pattern-bound `Ok`/`Err` payload name was never
// resolved against it, surfacing (only later, at its first read) as a
// confusing T0115 "cannot resolve name" panic when the enclosing function
// was ALSO async (its body then Phase-B-synthesizes a MoveNext method).
// `buildResultMatch`/`buildOptionMatch` now wrap the scrutinee in an
// implicit `EAwait` — unless one is already there — matching the language
// reference's "a direct call to an async function awaits in place with or
// without the `await` keyword" rule (docs/01 §7.1).
async func asyncMayFailProp(n: in Int): Result[Int, String] {
  if n < 0 {
    return Err("negative")
  }
  Ok(n * 2)
}

// The exact #6920 repro shape: `?` applied directly to a call to an async
// function, inside another async function's body, with no literal `await`.
async func asyncChainImplicit(): Result[Int, String] {
  val a = asyncMayFailProp(3)?
  val b = asyncMayFailProp(4)?
  Ok(a + b)
}

async func asyncChainImplicitErr(): Result[Int, String] {
  val a = asyncMayFailProp(-1)?
  val b = asyncMayFailProp(4)?
  Ok(a + b)
}

// The #6920-reported workaround — `?` applied to an explicit `(await ...)` —
// must keep compiling and computing the identical result: `isAlreadyAwaitedExpr`
// must recognise the existing `EAwait` and skip the implicit wrap rather than
// double-awaiting it.
async func asyncChainExplicit(): Result[Int, String] {
  val a = (await asyncMayFailProp(3))?
  val b = (await asyncMayFailProp(4))?
  Ok(a + b)
}

test "async Result `?`: implicit-await propagation on a direct async call (#6920)" {
  val result = await asyncChainImplicit()
  assertEqualInt(resultValue(result), 14, "3*2 + 4*2 = 14")
  assertEqual(resultLabel(result), "ok", "no early return")
}

test "async Result `?`: implicit-await propagation short-circuits on Err (#6920)" {
  val result = await asyncChainImplicitErr()
  assertEqual(resultLabel(result), "negative", "negative input ? -> Err, second call never evaluated")
}

test "async Result `?`: explicit (await ...)? still compiles and matches the implicit form (#6920)" {
  val result = await asyncChainExplicit()
  assertEqualInt(resultValue(result), 14, "explicit-await workaround computes the same value")
}

// The implicit-await wrap must be a safe no-op for a `?` whose operand is
// NOT an async call (the overwhelmingly common case) — a plain synchronous
// `Result`-returning call inside an async function's body.
async func asyncChainMixed(a: in Int, b: in Int): Result[Int, String] {
  val x = okIf(a > 0, a, "a")?
  val y = asyncMayFailProp(b)?
  Ok(x + y)
}

test "async Result `?`: implicit await is a no-op for a non-async operand mixed with an async one (#6920)" {
  val result = await asyncChainMixed(5, 3)
  assertEqualInt(resultValue(result), 11, "5 + 3*2 = 11")
  assertEqual(resultLabel(await asyncChainMixed(-1, 3)), "a", "sync ? still short-circuits first")
}

async func asyncOptDiv(n: in Int, d: in Int): Option[Int] {
  if d == 0 {
    None
  } else {
    Some(n / d)
  }
}

// Option-flavored async chain — implicit-await propagation on `Some`/`None`.
async func asyncOptChainImplicit(n: in Int, d1: in Int, d2: in Int): Option[Int] {
  val a = asyncOptDiv(n, d1)?
  val b = asyncOptDiv(a, d2)?
  Some(b)
}

test "async Option `?`: implicit-await propagation on a direct async call (#6920)" {
  assertEqualInt(optTag(await asyncOptChainImplicit(20, 2, 5)), 2, "20/2/5 = 2")
  assertEqualInt(optTag(await asyncOptChainImplicit(20, 0, 5)), -1, "divide-by-zero ? -> None")
}

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

// ── F0045: implicit-await ? inside try/catch/finally in an async func
//    (#7170, review finding on #6920's fix) ──────────────────────────────────
// V0012 (`modechecker_check.l`) rejects a literal `await` inside a
// try/catch/finally in an async function, because it runs during mode
// checking — BEFORE this pass synthesizes the #6920 implicit `EAwait` for a
// bare `mayFail(n)?` — so it can never see the implicit form.  Left
// unguarded, that combination would regress from a safe (if confusing)
// pre-#6920 T0115 compile failure to invalid IL that builds and crashes at
// JIT/runtime.  `implicitAwaitScrutinee` now rejects it here instead, with a
// dedicated F0045 diagnostic.
val asyncMayFailSrc = "async func mayFail(n: in Int): Result[Int, String] {\n  if n < 0 {\n    Err(\"neg\")\n  } else {\n    Ok(n)\n  }\n}\n"

test "F0045: implicit-await ? in a try body in an async function emits diagnostic" {
  val src = "package P\n" + asyncMayFailSrc +
    "async func f(n: in Int): Result[Int, String] {\n  try {\n    val x = mayFail(n)?\n    Ok(x)\n  } catch Bug as b {\n    Err(b.message)\n  }\n}\n"
  val result = lowerPropagateFile(parse(src).file)
  assertTrue(propHasDiag(result.diagnostics, "F0045"), "F0045 emitted for implicit-await ? in a try body")
  assertFalse(propHasDiag(result.diagnostics, "F0020"), "not the unrelated F0020 diagnostic")
}

test "F0045: implicit-await ? in a catch handler in an async function emits diagnostic" {
  val src = "package P\n" + asyncMayFailSrc +
    "async func f(n: in Int): Result[Int, String] {\n  try {\n    Ok(0)\n  } catch Bug as b {\n    val x = mayFail(n)?\n    Ok(x)\n  }\n}\n"
  val result = lowerPropagateFile(parse(src).file)
  assertTrue(propHasDiag(result.diagnostics, "F0045"), "F0045 emitted for implicit-await ? in a catch handler")
}

test "F0045: implicit-await ? in a finally block in an async function emits diagnostic" {
  val src = "package P\n" + asyncMayFailSrc +
    "async func f(n: in Int): Result[Int, String] {\n  try {\n    Ok(0)\n  } finally {\n    val x = mayFail(n)?\n  }\n}\n"
  val result = lowerPropagateFile(parse(src).file)
  assertTrue(propHasDiag(result.diagnostics, "F0045"), "F0045 emitted for implicit-await ? in a finally block")
}

test "F0045: does not fire for an explicit (await ...)? in a try body — that spelling is V0012's job" {
  val src = "package P\n" + asyncMayFailSrc +
    "async func f(n: in Int): Result[Int, String] {\n  try {\n    val x = (await mayFail(n))?\n    Ok(x)\n  } catch Bug as b {\n    Err(b.message)\n  }\n}\n"
  val result = lowerPropagateFile(parse(src).file)
  assertFalse(
    propHasDiag(result.diagnostics, "F0045"),
    "explicit await is untouched by this guard (isAlreadyAwaitedExpr short-circuits before it)"
  )
}

test "F0045: does not fire for implicit-await ? outside any try in an async function (#6920's own fix)" {
  val src = "package P\n" + asyncMayFailSrc +
    "async func f(n: in Int): Result[Int, String] {\n  val x = mayFail(n)?\n  Ok(x)\n}\n"
  val result = lowerPropagateFile(parse(src).file)
  assertFalse(
    propHasDiag(result.diagnostics, "F0045"),
    "#6920's own fix is unaffected when there is no try around the ?"
  )
}

test "F0045: does not fire for implicit-await ? in a try body when the enclosing function is NOT async" {
  // A plain (non-async) function's implicit await lowers to a blocking
  // `GetAwaiter().GetResult()` shim, not a suspend/resume state machine —
  // no CLR protected-region hazard, so the guard must only fire for
  // `st.curFnAsync`.
  val src = "package P\n" + asyncMayFailSrc +
    "func f(n: in Int): Result[Int, String] {\n  try {\n    val x = mayFail(n)?\n    Ok(x)\n  } catch Bug as b {\n    Err(b.message)\n  }\n}\n"
  val result = lowerPropagateFile(parse(src).file)
  assertFalse(propHasDiag(result.diagnostics, "F0045"), "sync enclosing function never hits the async/try guard")
}

test "F0045: a nested async func declared inside an outer try starts its own fresh (non-try) context" {
  // `inner`'s own `?` is not textually inside any try/catch/finally OF
  // `inner`'s OWN body — only inside the outer function's try, which does
  // not apply to a separately-framed nested function (stateForFn resets
  // inTry=false on every function entry, matching V0012's ELambda reset).
  val src = "package P\n" + asyncMayFailSrc +
    "async func outer(n: in Int): Result[Int, String] {\n  try {\n    async func inner(m: in Int): Result[Int, String] {\n      val y = mayFail(m)?\n      Ok(y)\n    }\n    Ok(n)\n  } catch Bug as b {\n    Err(b.message)\n  }\n}\n"
  val result = lowerPropagateFile(parse(src).file)
  assertFalse(propHasDiag(result.diagnostics, "F0045"), "nested function's own ? is outside its own try region")
}

// #7179: review finding — `rewriteExpr`'s `ELambda` case did not reset
// `st.inTry` before descending into the lambda body, unlike `stateForFn`
// (named functions) and V0012's own `walkExprForAwaitInTry` `ELambda` case.
// This never actually produced a live F0045 false positive: a `?` written
// directly in a lambda body classifies as `PropInLambda` (its own `F0020`)
// before `implicitAwaitScrutinee`/F0045 is ever reached — verified directly
// against the built compiler before this fix landed. `stateForLambda` (the
// fix) closes the latent state-tracking gap anyway, matching V0012's
// invariant exactly. This test pins both properties: no F0045 leaks out,
// and the (correct, pre-existing) F0020 still fires for the `?` itself.
test "F0045/F0020 (#7179): a lambda body nested in a try region gets F0020 for its own ?, never F0045" {
  val src = "package P\n" + asyncMayFailSrc +
    "async func f(n: in Int): Result[Int, String] {\n  try {\n    val g = \\() -> {\n      val x = mayFail(n)?\n      x\n    }\n    Ok(0)\n  } catch Bug as b {\n    Err(b.message)\n  }\n}\n"
  val result = lowerPropagateFile(parse(src).file)
  assertFalse(
    propHasDiag(result.diagnostics, "F0045"),
    "a lambda body is never inside the enclosing function's own try region"
  )
  assertTrue(
    propHasDiag(result.diagnostics, "F0020"),
    "? inside a lambda body still gets its own lambda-specific diagnostic"
  )
}

// #7174: review finding on #7170's fix — the guard above fired for ANY `?`
// scrutinee inside a try/catch/finally in an async function, not just a
// direct call to a KNOWN async function.  A call to an ordinary (non-async)
// function, and a bare local variable, are both already safe (`EAwait`'s
// codegen is a no-op when the value isn't Task-shaped — see the #6920 doc
// above `implicitAwaitScrutinee`), so F0045 must not fire for either.
val syncValidateSrc = "func validate(n: in Int): Result[Int, String] {\n  if n < 0 {\n    Err(\"neg\")\n  } else {\n    Ok(n)\n  }\n}\n"

test "F0045 (#7174): does not fire for ? on a call to a non-async function in a try body" {
  val src = "package P\n" + syncValidateSrc +
    "async func f(n: in Int): Result[Int, String] {\n  try {\n    val x = validate(n)?\n    Ok(x)\n  } catch Bug as b {\n    Err(b.message)\n  }\n}\n"
  val result = lowerPropagateFile(parse(src).file)
  assertFalse(propHasDiag(result.diagnostics, "F0045"), "a call to a non-async function is never Task-shaped")
}

test "F0045 (#7174): does not fire for ? on a bare local variable in a try body" {
  val src = "package P\nasync func f(n: in Int): Result[Int, String] {\n  try {\n    val r: Result[Int, String] = Ok(n)\n    val x = r?\n    Ok(x)\n  } catch Bug as b {\n    Err(b.message)\n  }\n}\n"
  val result = lowerPropagateFile(parse(src).file)
  assertFalse(propHasDiag(result.diagnostics, "F0045"), "a bare local variable is never Task-shaped")
}

test "F0045 (#7174): still fires for implicit-await ? on a same-file async call in a try body" {
  // Regression guard: the narrowing must not have broken the original
  // #7170 case it was meant to keep catching.
  val src = "package P\n" + asyncMayFailSrc +
    "async func f(n: in Int): Result[Int, String] {\n  try {\n    val x = mayFail(n)?\n    Ok(x)\n  } catch Bug as b {\n    Err(b.message)\n  }\n}\n"
  val result = lowerPropagateFile(parse(src).file)
  assertTrue(
    propHasDiag(result.diagnostics, "F0045"),
    "a direct call to a known same-file async function is still flagged"
  )
}

// #7178: review finding on #7174's fix — `isDirectCallToKnownAsyncFn` only
// recognized a same-file bare-name call, so three genuinely hazardous
// shapes silently fell through to the implicit-await wrap with NO F0045
// diagnostic: a cross-package/qualified call, a method call, and a call to
// a locally-nested `async func` (never collected into any same-file
// top-level name set).  All three can be truly async, so silently treating
// them as safe regresses exactly the invalid-IL hazard F0045 exists to
// close.  The guard (`isRiskyTryCallScrutinee`) was rebuilt to flag
// anything it cannot PROVE safe rather than assume safety by default.
test "F0045 (#7178): fires for ? on a cross-package/qualified call in a try body" {
  val src = "package P\nasync func f(n: in Int): Result[Int, String] {\n  try {\n    val x = OtherPkg.mayFail(n)?\n    Ok(x)\n  } catch Bug as b {\n    Err(b.message)\n  }\n}\n"
  val result = lowerPropagateFile(parse(src).file)
  assertTrue(propHasDiag(result.diagnostics, "F0045"), "a qualified call cannot be proven non-async, so it is flagged")
}

test "F0045 (#7178): fires for ? on a method-call scrutinee in a try body" {
  val src = "package P\nrecord Box { r: Result[Int, String] }\nasync func f(box: in Box): Result[Int, String] {\n  try {\n    val x = box.fetch()?\n    Ok(x)\n  } catch Bug as b {\n    Err(b.message)\n  }\n}\n"
  val result = lowerPropagateFile(parse(src).file)
  assertTrue(propHasDiag(result.diagnostics, "F0045"), "a method call cannot be proven non-async, so it is flagged")
}

test "F0045 (#7178): fires for ? on a call to a locally-nested async func in the same try body" {
  val src = "package P\nasync func f(n: in Int): Result[Int, String] {\n  try {\n    async func helper(m: in Int): Result[Int, String] {\n      Ok(m)\n    }\n    val x = helper(n)?\n    Ok(x)\n  } catch Bug as b {\n    Err(b.message)\n  }\n}\n"
  val result = lowerPropagateFile(parse(src).file)
  assertTrue(
    propHasDiag(result.diagnostics, "F0045"),
    "a call to a locally-nested async func is never in the same-file top-level name set, so it is flagged"
  )
}

test "F0045 (#7178): still does not fire for a bare same-file non-async call or a builtin ctor in a try body" {
  // Regression guard: proven-safe shapes must stay unflagged after the
  // #7178 redesign flipped the default from "assumed safe" to "assumed
  // risky unless proven otherwise".
  val src = "package P\n" + syncValidateSrc +
    "async func f(n: in Int): Result[Int, String] {\n  try {\n    val x = validate(n)?\n    val y = Ok(x)?\n    Ok(y)\n  } catch Bug as b {\n    Err(b.message)\n  }\n}\n"
  val result = lowerPropagateFile(parse(src).file)
  assertFalse(
    propHasDiag(result.diagnostics, "F0045"),
    "a proven-non-async call and a builtin ctor call stay unflagged"
  )
}

// #7185: review finding — `isRiskyTryCallScrutinee` only inspected
// `ECall`/`EParen` scrutinees, so a composite `if`/`match`/`try`-as-
// -expression whose branches are direct async calls fell through the
// default `case _ -> false` (silently assumed safe) even though its value
// can genuinely be Task-shaped, exactly like a bare direct call.
test "F0045 (#7185): fires for ? on an if-expression scrutinee in a try body" {
  val src = "package P\n" + asyncMayFailSrc +
    "async func f(n: in Int): Result[Int, String] {\n  try {\n    val x = (if n > 0 { mayFail(n) } else { mayFail(0) })?\n    Ok(x)\n  } catch Bug as b {\n    Err(b.message)\n  }\n}\n"
  val result = lowerPropagateFile(parse(src).file)
  assertTrue(
    propHasDiag(result.diagnostics, "F0045"),
    "an if-expression scrutinee cannot be proven non-async, so it is flagged"
  )
}

test "F0045 (#7185): fires for ? on a match-expression scrutinee in a try body" {
  val src = "package P\n" + asyncMayFailSrc +
    "async func f(n: in Int): Result[Int, String] {\n  try {\n    val x = (match n {\n      case 0 -> mayFail(0)\n      case _ -> mayFail(n)\n    })?\n    Ok(x)\n  } catch Bug as b {\n    Err(b.message)\n  }\n}\n"
  val result = lowerPropagateFile(parse(src).file)
  assertTrue(
    propHasDiag(result.diagnostics, "F0045"),
    "a match-expression scrutinee cannot be proven non-async, so it is flagged"
  )
}

test "F0045 (#7185): fires for ? on a value-position try-expression scrutinee in a try body" {
  val src = "package P\n" + asyncMayFailSrc +
    "async func f(n: in Int): Result[Int, String] {\n  try {\n    val x = (try {\n      mayFail(n)\n    } catch Bug as b {\n      mayFail(0)\n    })?\n    Ok(x)\n  } catch Bug as b {\n    Err(b.message)\n  }\n}\n"
  val result = lowerPropagateFile(parse(src).file)
  assertTrue(
    propHasDiag(result.diagnostics, "F0045"),
    "a value-position try-expression scrutinee (EBlock ending in STry) cannot be proven non-async, so it is flagged"
  )
}

// ── Same-file alias return types (#1814) ─────────────────────────────────────
// `monadOfRet` unfolds same-file `alias` declarations before the Result/Option
// classification, so a return type written through an alias no longer trips a
// false F0020.
test "alias of Result: ? classifies as PropResult, no F0020 (#1814)" {
  val src = "package P\nalias ParseResult[T] = Result[T, String]\nfunc f(): ParseResult[Int] {\n  val r: Result[Int, String] = Ok(1)\n  val v = r?\n  Ok(v)\n}\n"
  val result = lowerPropagateFile(parse(src).file)
  assertEqualInt(result.diagnostics.count, 0, "no diagnostics for ? behind a Result alias")
}

test "alias of Option: ? classifies as PropOption, no F0020 (#1814)" {
  val src = "package P\nalias Maybe[T] = Option[T]\nfunc g(): Maybe[Int] {\n  val o: Option[Int] = Some(1)\n  val v = o?\n  Some(v)\n}\n"
  val result = lowerPropagateFile(parse(src).file)
  assertEqualInt(result.diagnostics.count, 0, "no diagnostics for ? behind an Option alias")
}

test "non-generic alias of Result: TRef return type also unfolds (#1814)" {
  val src = "package P\nalias IntResult = Result[Int, String]\nfunc f(): IntResult {\n  val r: Result[Int, String] = Ok(1)\n  val v = r?\n  Ok(v)\n}\n"
  val result = lowerPropagateFile(parse(src).file)
  assertEqualInt(result.diagnostics.count, 0, "no diagnostics for ? behind a non-generic Result alias")
}

test "chained alias of Result unfolds through both hops (#1814)" {
  val src = "package P\nalias Inner[T] = Result[T, String]\nalias Outer[T] = Inner[T]\nfunc f(): Outer[Int] {\n  val r: Result[Int, String] = Ok(1)\n  val v = r?\n  Ok(v)\n}\n"
  val result = lowerPropagateFile(parse(src).file)
  assertEqualInt(result.diagnostics.count, 0, "no diagnostics for ? behind a chained alias")
}

test "non-monadic alias still fires F0020 (#1814)" {
  val src = "package P\nalias Ints = List[Int]\nfunc f(): Ints {\n  val r: Result[Int, String] = Ok(1)\n  val v = r?\n  newList()\n}\n"
  val result = lowerPropagateFile(parse(src).file)
  assertTrue(propHasDiag(result.diagnostics, "F0020"), "F0020 still fires when the alias is not Result/Option")
}

test "cyclic alias classifies as PropOther without looping (#1814)" {
  val src = "package P\nalias A = B\nalias B = A\nfunc f(): A {\n  val r: Result[Int, String] = Ok(1)\n  val v = r?\n  v\n}\n"
  val result = lowerPropagateFile(parse(src).file)
  assertTrue(propHasDiag(result.diagnostics, "F0020"), "cyclic alias hits the depth bound and fires F0020")
}

// NOTE: runtime end-to-end coverage of `?` behind an alias is blocked on a
// pre-existing MSIL backend gap independent of the propagation pass: a value
// returned through `alias IntResult = Result[Int, String]` is constructed as
// a distinct generic instantiation, so a downstream `match` on it traps with
// "match not exhaustive ... scr=GStd.Core.Result<I,S,>" even with no `?`
// involved (and module-level generic alias parameters fail T0010 in the
// self-hosted type checker).  Tracked in #3267; the alias classification
// itself is fully covered by the AST-level tests above.
