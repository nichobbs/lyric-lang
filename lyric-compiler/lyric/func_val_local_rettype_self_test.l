//! func_val_local_rettype_self_test.l — #5774 (found while investigating
//! #5304): an un-annotated local bound from a call to a function whose OWN
//! declared return type is itself function-shaped
//! (`func makeAdder(x: Int): (Int) -> Int { ... }`, `val f = makeAdder(5)`,
//! no `(Int) -> Int` annotation on `f`) never registered `f`'s return type in
//! `fctx.funcValRetTypes`.  Invoking `f` later left the delegate's boxed
//! `object` result un-unboxed, which — whenever that boxed value was then
//! used somewhere requiring the real value type (most sharply: returned
//! directly as a function's own typed result) — produced genuinely invalid
//! IL: `ilverify` reported `[StackUnexpected] found object, expected Int32`,
//! and the compiled program returned a different garbage integer on every
//! run of the SAME binary (an unboxed object-reference bit pattern read as
//! Int32).  Reproduced in a plain single-file build — no multi-package
//! bundle or cross-package call required, despite #5304's original
//! description implicating package-bundle ordering specifically.
//!
//! Fixed by extending the existing #5511 "function-typed record field"
//! inference path (`cctx.fieldFuncRetTypes`/`recordFieldFuncKeyMsil`,
//! originally for `val fld = h.f`) to also recognise a plain call to a known
//! same-package top-level function whose declared return type is
//! `TFunction`, registered once per function in `addPackageTokens`'s IFunc
//! pass under a `"func:" + pkgName + "." + funcName` key.
//!
//! #5790 (review finding on the original #5774 fix): the initial landing
//! keyed this registration by BARE name only, first-registration-wins — which
//! let a same-name overload at a DIFFERENT arity (D-progress-324/#1536:
//! overloading by arity is a shipped, tested feature) silently steal another
//! overload's function-value return/param types, reproducing the same
//! miscompile class this fix exists to close.  Fixed by arity-qualifying the
//! key (mirroring `funcRetTypes`' `arityKey`/bare-name dual registration and
//! its call-site arity-first lookup precedence); the bare-name key remains as
//! a fallback only.  See the last test below for the regression case.
//!
//! Run in CI via native `lyric test --target dotnet`:
//!
//!   lyric test lyric-compiler/lyric/func_val_local_rettype_self_test.l
//!
//! Verified (but not yet CI-wired) on `--target jvm` too — see the #5796 note
//! below; a `ci.yml` "on JVM" step alongside this file's existing dotnet
//! step (mirroring e.g. the `Bool stringification self-test on JVM` step)
//! would close that gap.
//!
//! The fix itself lives in `msil/codegen.l` (MSIL-only; #5304's original
//! panic-based repro was also MSIL/`Msil.Lowering`-specific), but this test
//! module imports only `Std.*` and runs unmodified on both targets. #5796
//! (review finding) checked JVM parity: the JVM backend's `lowerLambdaInvoke`
//! always returns a raw `Object` and relies on the surrounding expression's
//! context to narrow/unbox (a different strategy from MSIL's per-local
//! `fctx.funcValRetTypes` registry), so it is architecturally unaffected by
//! this defect class — all 7 cases here (including the #5790 arity-overload
//! regression) already pass against `--target jvm` with no JVM-side code
//! change. See D-progress-684's `#5796` addendum in `docs/03-decision-log.md`.
//!
//! #6392 addendum: chaining a call directly onto another call's RESULT
//! (`makeGreeter()()`, invoking the closure without first binding it to an
//! intermediate local) fell into `lowerCallMsil`'s default arm, which
//! evaluated the call's arguments but never lowered the callee expression
//! itself (nor emitted any invoke instruction) — `ilverify` confirmed
//! genuinely invalid IL (`StackUnderflow`). JVM's `lowerCall` had the exact
//! same gap (`VerifyError: Operand stack underflow`). Fixed on both targets
//! by generalizing the default arm to lower the callee expression in place
//! and invoke it through the same uniform boxed-`Func`/functional-interface
//! ABI a named function-typed local already uses (MSIL: the `Some(slot)` arm
//! in `lowerCallMsil`; JVM: `lowerLambdaInvoke`) — on MSIL, the real nested
//! return type is recovered via `recordFieldFuncKeyMsil`/
//! `cctx.fieldFuncRetTypes` (the same #5774 registry above) so the result is
//! unboxed, not just left as `object`.
//!
//! #6394 addendum: the #6392 regression cases above deliberately asserted via
//! arithmetic/comparison rather than `println` on JVM, because `println`ing a
//! lambda-invoke result directly hit a SEPARATE, pre-existing JVM-only defect:
//! `printArgType` (`lyric-compiler/jvm/codegen/04_calls.l`) assumed any
//! non-primitive `println` argument was statically `java/lang/String`, but
//! `lowerLambdaInvoke`/`lowerCallOnExprResult` track an invoke result as raw
//! `java/lang/Object` per their #5796/#6392 convention — `println(reader())`
//! then emitted `invokevirtual println(String)` against an `Object` on the
//! verifier's tracked stack, a `VerifyError: Bad type on operand stack`. Fixed
//! by routing `JRef("java/lang/Object")` println/print arguments through the
//! `PrintStream.println(Object)`/`.print(Object)` overload (itself
//! `String.valueOf`-backed, so it renders correctly whatever the erased
//! value's real runtime type is — String, boxed Integer, etc.) instead of
//! guessing `println(String)`. The two `println`-on-invoke-result cases below
//! are the regression proof this addendum promised.
//!
//! #6398 addendum: unlike #6392's arithmetic case (`makeAdder(5)(10) + 1`,
//! where the literal `1` anchors the JVM `reconcileCmpOperands` fallback to a
//! numeric type), summing/comparing TWO Object-erased chained-call results
//! with no other anchor (`makeAdder(1)(2) + makeAdder(3)(4)`) previously fell
//! through the JVM `BAdd` lowering's blind "both operands are references ->
//! string concatenation" branch, silently computing `"3" + "7"` = `"37"`
//! instead of `10` — a wrong-VALUE miscompile, not a crash. Fixed on the JVM
//! backend by recovering the closure's real static return type at the
//! invoke site: `closureInvokeRetType`/`JvmFuncSig.closureRetTy` for a direct
//! chained call, and `ctx.funcValRetTypes`/`recordFuncValRetType` (mirroring
//! this file's own #5774 MSIL registry) for a NAMED local bound from such a
//! call — both unbox the invoke's `Object` result to its real primitive type
//! before it ever reaches an arithmetic/comparison op. A residual
//! genuinely-unresolvable case (e.g. two un-annotated LAMBDA-LITERAL locals
//! summed, as opposed to two calls to a known top-level function) now fails
//! loudly at compile time (`Jvm.Codegen: '+' on two operands whose runtime
//! type is fully erased to Object could not be resolved…`) instead of
//! silently guessing, per the fail-loudly principle — see
//! `reconcileCmpOperands`'s `isFullyErasedObjectJvm` guard and the matching
//! `BAdd` guard in `lyric-compiler/jvm/codegen/02_exprs.l`.
@test_module
package Lyric.FuncValLocalRetTypeSelfTest

import Std.Core
import Std.Testing

// HOF returning a closure: the shape that #5774 hit.
func makeAdder(x: in Int): (Int) -> Int {
  { y: Int -> x + y }
}

func makeGreeter(name: in String): () -> String {
  { -> "hello, " + name }
}

func makeMultiParam(scale: in Int): (Int, Int) -> Int {
  { a: Int, b: Int -> (a + b) * scale }
}

test "un-annotated closure local, invoked and directly returned (#5774 exact repro)" {
  assertEqualInt(directReturn(), 15, "directReturn() == 15")
}

func directReturn(): Int {
  val f = makeAdder(5)
  f(10)
}

test "un-annotated closure local, invoked and stored before use" {
  val f = makeAdder(7)
  val r = f(3)
  assertEqualInt(r, 10, "makeAdder(7)(3) == 10")
}

test "un-annotated closure local, invoked twice with different arguments" {
  val f = makeAdder(1)
  assertEqualInt(f(1), 2, "makeAdder(1)(1) == 2")
  assertEqualInt(f(100), 101, "makeAdder(1)(100) == 101")
}

test "un-annotated closure local, zero-arg / String-returning" {
  val greet = makeGreeter("world")
  assertEqual(greet(), "hello, world", "makeGreeter(\"world\")() == \"hello, world\"")
}

test "un-annotated closure local, two-parameter" {
  val f = makeMultiParam(2)
  assertEqualInt(f(3, 4), 14, "makeMultiParam(2)(3,4) == (3+4)*2 == 14")
}

test "explicitly-annotated closure local still works (pre-existing path, no regression)" {
  val f: (Int) -> Int = makeAdder(5)
  assertEqualInt(f(10), 15, "annotated makeAdder(5)(10) == 15")
}

// Two same-name overloads (D-progress-324/#1536) at different arities, each
// returning a DIFFERENT function-shaped type.  #5790: a bare-name-only key
// would let the second overload's call site silently inherit the first
// overload's return/param types.
func makeOp(x: in Int): (Int) -> Int {
  { y: Int -> x + y }
}

func makeOp(x: in Int, label: in String): () -> String {
  { -> label + toString(x) }
}

test "overloaded HOF-returning functions at different arities resolve independently (#5790)" {
  val f = makeOp(5)
  assertEqualInt(f(10), 15, "makeOp(5)(10) == 15 (1-arity overload)")
  val g = makeOp(7, "n=")
  assertEqual(g(), "n=7", "makeOp(7, \"n=\")() == \"n=7\" (2-arity overload)")
}

// #6392: the callee of the chained call is itself an `ECall`, not a bare
// `EPath` naming a slot — the exact shape that was silently dropped.
test "direct chained call, no intermediate local (#6392 exact repro)" {
  assertEqualInt(makeAdder(5)(10), 15, "makeAdder(5)(10) == 15")
}

test "direct chained call, zero-arg / String-returning (#6392)" {
  assertEqual(makeGreeter("world")(), "hello, world", "makeGreeter(\"world\")() == \"hello, world\"")
}

test "direct chained call with multiple arguments (#6392)" {
  assertEqualInt(makeMultiParam(2)(3, 4), 14, "makeMultiParam(2)(3, 4) == 14")
}

// The callee is `EParen(ECall(...))` rather than a bare `ECall` — exercises
// the `lowerCallMsil`/`lowerCall` `EParen` unwrap arm added alongside the fix.
test "parenthesized chained call (#6392)" {
  assertEqualInt((makeAdder(5))(10), 15, "(makeAdder(5))(10) == 15")
}

// Arithmetic on the chained call's result proves the returned value is
// actually unboxed to `Int`, not left as a boxed `object` on the stack.
test "chained call result used directly in arithmetic, unboxing proof (#6392)" {
  assertEqualInt(makeAdder(5)(10) + 1, 16, "makeAdder(5)(10) + 1 == 16")
}

// Two-deep chain: `makeMakerAdder(5)` returns a closure that itself returns
// a closure, invoked twice in a row with no intermediate binding at all.
func makeMakerAdder(x: in Int): () -> (Int) -> Int {
  { -> { y: Int -> x + y } }
}

test "two-deep chained call (#6392)" {
  assertEqualInt(makeMakerAdder(5)()(10), 15, "makeMakerAdder(5)()(10) == 15")
}

// #6394: `println` of a lambda-invoke result, String-returning. On JVM this
// hit `printArgType`'s Object/String mismatch (VerifyError); on MSIL it
// always worked. Passing means both targets compiled and ran this without
// crashing; the `assertEqual` line proves the underlying value itself.
test "println on a named-local lambda-invoke result, String-returning (#6394)" {
  val reader = makeGreeter("world")
  println(reader())
  assertEqual(reader(), "hello, world", "makeGreeter(\"world\")() == \"hello, world\"")
}

// #6394: `println` of a direct chained call's Int result — the erased
// `Object` stack value is a boxed Integer here, not a String, exercising the
// `PrintStream.println(Object)` fix path with a non-String runtime type.
test "println on a direct chained call's Int result (#6394)" {
  println(makeAdder(5)(10))
  assertEqualInt(makeAdder(5)(10), 15, "makeAdder(5)(10) == 15")
}

// #6398: `+` (and comparison) on TWO Object-erased chained-call results — the
// gap #6392's arithmetic case above didn't cover, because ONE operand there
// was always a primitive literal (`makeAdder(5)(10) + 1`), which anchored the
// numeric type for the JVM backend's `reconcileCmpOperands` fallback. With
// BOTH operands erased to `java/lang/Object` (two closure invokes, neither
// side a literal), the pre-fix JVM `BAdd` lowering saw two references and
// unconditionally dispatched to string concatenation — `makeAdder(1)(2) +
// makeAdder(3)(4)` silently computed `"3" + "7"` = `"37"` instead of `10`,
// then a following `==` against the literal `10` threw `ClassCastException`
// (MSIL was unaffected — see the module docstring; unrelated to this file's
// F#-era #5774/#6392 fix). Fixed by recovering the closure's real static
// return type at the invoke site (`closureInvokeRetType`/`funcValRetTypes`)
// so the JVM backend unboxes to `Int` before either operand reaches an
// arithmetic/comparison op, mirroring this file's #5774/#6392 registries.
test "sum of two direct chained-call results, both Object-erased (#6398 exact repro)" {
  assertEqualInt(makeAdder(1)(2) + makeAdder(3)(4), 10, "makeAdder(1)(2) + makeAdder(3)(4) == 10")
}

// Same defect on two NAMED locals bound from closure-returning calls, no
// direct chaining — the `funcValRetTypes`/`recordFuncValRetType` half of the
// #6398 fix (`closureInvokeRetType` alone only covers the direct-chain shape
// above).
test "sum of two named-local closure invokes, both Object-erased (#6398)" {
  val f = makeAdder(1)
  val g = makeAdder(3)
  assertEqualInt(f(2) + g(4), 10, "f(2) + g(4) == 10 where f/g are un-annotated closure locals")
}

// Subtraction / multiplication on two Object-erased operands: BSub/BMul share
// `reconcileCmpOperands` with the comparison ops (not BAdd's separate
// string-concat-guessing path), where the pre-fix both-erased fallback was a
// documented-but-unreproduced gap (#2862) that emitted a primitive
// instruction directly on two references (a JVM `VerifyError` at class load,
// not a silent wrong value) — closed by the same closure-invoke-site fix.
test "subtraction and multiplication of two direct chained-call results (#6398)" {
  assertEqualInt(makeAdder(10)(0) - makeAdder(3)(0), 7, "10 - 3 == 7, both operands erased")
  assertEqualInt(makeMultiParam(1)(3, 0) * makeMultiParam(1)(2, 0), 6, "3 * 2 == 6, both operands erased")
}

// Comparison (`==`) of two direct chained-call results with NO arithmetic in
// between — proves the fix covers `lowerCmpExpr`/`reconcileCmpOperands`
// directly, not just as a downstream effect of a corrected `BAdd`.
test "comparison of two direct chained-call results, both Object-erased (#6398)" {
  assertTrue(makeAdder(1)(2) == makeAdder(3)(0), "makeAdder(1)(2) == makeAdder(3)(0), both == 3")
  assertTrue(makeAdder(1)(2) < makeAdder(9)(9), "3 < 18")
  assertTrue(makeAdder(9)(9) > makeAdder(1)(2), "18 > 3")
}

// Value equality on two operands that stay fully erased to Object even after
// the #6398 unboxing (a generic record's field read has no closure-invoke
// site to recover the type at).  `==`/`!=` on two erased references must keep
// dispatching through the null-safe `Objects.equals` value-equality path —
// round 14's first fail-loud guard wrongly panicked here (#6401); the guard
// is now scoped to the arithmetic call sites only.
record BoxEq6401[T] {
  value: T
}

test "equality on two fully-erased generic-field reads still works (#6401)" {
  val a = BoxEq6401(value = 5)
  val b = BoxEq6401(value = 5)
  val c = BoxEq6401(value = 7)
  assertTrue(a.value == b.value, "boxed 5 == boxed 5 via Objects.equals")
  assertTrue(a.value != c.value, "boxed 5 != boxed 7 via Objects.equals")
}

// #6399 addendum: `lowerLambdaInvokeTail`'s JVoid arm (round 14, JVM-only —
// a Unit-returning closure invoked through a chain still pushes SOME boxed
// placeholder per the uniform invoke ABI, so the arm pops it explicitly
// since `coerceArgTo` has no JVoid target arm) had no test coverage. Without
// that pop, the boxed placeholder stays on the operand stack after the
// chained invoke and corrupts everything lowered afterward.
func makeSideEffect6399(): () -> Unit {
  { -> println("makeSideEffect6399 ran") }
}

test "chained call to a Unit-returning closure factory leaves the stack balanced (#6399 addendum)" {
  makeSideEffect6399()()
  assertEqualInt(1 + 1, 2, "computation after a chained Unit-closure invoke is unaffected")
}

// #6690: unlike every case above (a `val` bound to a CALL whose result is
// function-shaped), this is a `val` bound directly to a LAMBDA LITERAL with
// no type annotation at all (`val f = { x -> false }`). `registerFieldFuncValTypesMsil`
// had no `ELambda` arm, so `f`'s return type never registered and invoking
// `f(y)` left the boxed `Func::Invoke` result un-unboxed — a non-null boxed
// reference reads as truthy regardless of the lambda's real body, so `f(y)`
// was silently `true` even though every lambda here always returns `false`.
// Uses the brace-lambda form rather than the bare-paren-arrow sugar
// (`(x) -> false`) shown in #6690's original repro: the two are equivalent
// for an untyped single param, but the bare-paren form trips the unrelated
// `lyric fmt` bug #6869 (any file containing one is refused with
// "formatting would change the code-token sequence"); the brace form
// formats cleanly and exercises the identical codegen path.
test "un-annotated lambda-literal local, boolean body (#6690 exact repro)" {
  val f = { x -> false }
  assertFalse(f(1), "f(1) must be false, not truthy-boxed-object")
  assertFalse(f(99), "f(99) must be false, not truthy-boxed-object")
}

// The lambda body is a comparison (`EBinop`) rather than a bare literal —
// exercises `inferUntypedStaticValMsilType`'s `BGt` (always-`MBool`) arm via
// the shared inference path. Compares a captured OUTER value rather than the
// lambda's own param: the param stays genuinely unused/untyped so this
// case is orthogonal to the pre-existing, deliberate #1939 diagnostic
// ("a lambda that uses an un-annotated parameter … is not yet supported"),
// which is unrelated to #6690 and fires only when an unannotated param's
// VALUE itself needs unboxing. Brace-lambda form, same #6869 rationale as
// the test above.
test "un-annotated lambda-literal local, comparison body over a captured value (#6690)" {
  val threshold = 3
  val exceeds = { x -> threshold > 0 }
  assertTrue(exceeds(999), "threshold(3) > 0 is true regardless of the unused param x")
}

// The lambda's parameter carries an EXPLICIT type annotation (only legal via
// the brace `{ params -> body }` form — the bare-paren-arrow sugar accepts
// untyped identifiers only, per grammar.ebnf §7.1.3.1) and the body returns
// it directly (`EPath`) — exercises the fix's `paramEnv` lookup, not just
// the literal/comparison arms the other cases here cover. Also exercises a
// multi-statement block body, proving `blockTrailingExprMsil` picks the
// LAST statement's value, not the first.
test "un-annotated lambda-literal local, typed param + multi-statement block body (#6690)" {
  val overTen = { x: Int -> val doubled = x * 2; doubled > 10 }
  assertTrue(overTen(6), "6*2 == 12 > 10")
  assertFalse(overTen(2), "2*2 == 4, not > 10")
}

// A bare-param trailing expression, `x` itself: exercises the fix's
// `paramEnv` `EPath` lookup directly (the "typed param" test above only
// covers `EPath` as an OPERAND of `>`, never as the ENTIRE trailing
// expression) — review SUGGESTION on #6690's own PR.
test "un-annotated lambda-literal local, bare typed-param trailing expression (#6690 review)" {
  val identity = { x: Int -> x }
  assertEqualInt(identity(41), 41, "identity(41) == 41 via paramEnv EPath lookup")
}

// #6932 (review REQUIRED on #6690's own PR — investigated, NOT reproducible
// as described, see below): claimed that an unannotated-BINDING lambda
// literal whose body's only statement is an explicit `return <value>` was
// misclassified as `MVoid` by the original fix (its trailing-value search
// found no `SExpr` last statement), and that calling it as a value would
// corrupt the operand stack. Verified this does NOT compile as literally
// described: a lambda body ending in `return <value>` types as `Never`
// (`checkBlock`'s divergence rule, `typechecker_stmts.l`), and passing a
// `Never`-typed call result as a plain call argument is rejected at compile
// time (`error[T0043]: argument type Never does not match parameter type
// …`) before codegen ever runs — confirmed with the issue's own exact
// repro. A permissive consuming position (a `Never`-typed call used as a
// function's own tail expression, where `Never` freely unifies) DOES
// compile and DOES crash at runtime with `NullReferenceException` — but
// verified that crash reproduces IDENTICALLY on `main` at 57b130e (the
// commit immediately before this PR's own base) with `return` inside a
// lambda passed DIRECTLY to a typed higher-order-function parameter (no
// `val` binding, no `registerFieldFuncValTypesMsil` involvement at all) —
// i.e. it is a pre-existing, unrelated "a `return` statement inside ANY
// lambda-literal body panics at runtime regardless of how its return type
// is registered" gap, not something this PR introduced or fixes. Filed
// separately as #6947 (out of `group:msil-codegen-correctness` scope; a
// materially different and much deeper bug than this PR's return-type-
// inference fix). `lambdaBodyTrailingValueMsil` (below) still unwraps an
// explicit trailing `return` as a value producer — a genuine, harmless
// correctness improvement over the `MVoid` guess it replaces — but no
// runtime regression test is added here: every reachable way to invoke such
// a lambda hits #6947's crash regardless of this fix, so there is no
// passing repro available to pin the type-inference improvement in
// isolation.
//
// #6933 (review REQUIRED on #6690's own PR): arithmetic over a CAPTURED
// (non-parameter) outer variable inside an unannotated-BINDING lambda
// literal was silently mis-inferred as `MInt` regardless of the captured
// variable's real type, because the original fix's arithmetic fallback
// treated any unresolvable operand (anything not in the lambda's own
// `paramEnv`, which covers only its explicitly-typed parameters — never a
// capture) as `MInt`. The captured operand is placed as the ARITHMETIC
// LEFT-HAND side (`rate + x`, not `x + rate`) since the underlying
// heuristic — both before and after this fix — infers an `EBinop`'s result
// type from its LHS alone; the captured-and-unresolvable operand must be
// the side actually consulted to exercise the bug. Binding the call result
// through an explicitly Double-ANNOTATED local (`val result: Double = ...`,
// the same established `#5519` real-unboxing-at-a-typed-bind pattern used
// elsewhere in this codebase) proves which type was actually registered: a
// wrong `MInt` registration throws `InvalidCastException` INSIDE the call's
// own invoke codegen (which unconditionally unboxes to the registered type
// before the value ever reaches the bind site), while the fix's correct
// `MObject` (unknown) registration defers the real unboxing to this bind,
// which resolves it correctly.
test "un-annotated lambda-literal local, arithmetic over a captured Double (#6933)" {
  val rate = 1.5
  val scale = { x: Double -> rate + x }
  val result: Double = scale(2.0)
  assertTrue(result == 3.5, "1.5 + 2.0 == 3.5 via a captured Double operand, not a wrong MInt guess")
}

// The captured operand is a `String` (BAdd's OTHER non-Int widening arm) —
// proves the fix's fallback isn't narrowly patched for `Double` alone.
test "un-annotated lambda-literal local, arithmetic over a captured String (#6933)" {
  val suffix = "!"
  val shout = { x: String -> suffix + x }
  val result: String = shout("hi")
  assertEqual(result, "!hi", "\"!\" + \"hi\" == \"!hi\" via a captured String operand")
}

// A comparison (`>`, always `MBool` regardless of either operand's type) over
// a captured value must still resolve correctly and is NOT rejected by the
// #6933 fix's more conservative arithmetic handling — this is the
// pre-existing "comparison body over a captured value (#6690)" test's own
// sibling, re-asserted here to pin that the #6933 fix does not regress the
// always-safe comparison arms.
test "un-annotated lambda-literal local, comparison over a captured Double is unaffected by #6933's fix" {
  val threshold = 2.5
  val exceeds = { x -> threshold > 1.0 }
  assertTrue(exceeds(999), "threshold(2.5) > 1.0 is true regardless of the unused param x")
}
