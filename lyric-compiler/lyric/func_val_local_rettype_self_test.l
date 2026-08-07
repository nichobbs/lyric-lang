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
