//! bare_func_ref_self_test.l — dual-target regression test for #5362/#5366
//! (MSIL) and their JVM counterpart, #6393.
//!
//! All three issues are the same subsystem: how each self-hosted backend
//! materializes and types a function-typed VALUE outside the strongly-typed-
//! lambda happy path (the closure-class ABI, docs/52/53, Epic #1877/D113).
//!
//!   • #5362 (MSIL) — a bare top-level named function used directly as a
//!     `(A,...) -> R`-typed value (`apply(double, 21)`, no wrapping closure
//!     literal) crashed at runtime with `NullReferenceException`: the
//!     `lowerExprMsil` EPath value-read fallback had no MethodDef whose
//!     PHYSICAL signature matched the uniform boxed `Func<object,...,object>`
//!     ABI to `ldftn` against.  Fixed by `synthesizeBareFuncRefThunksMsil`
//!     (`msil/codegen.l`), a pre-codegen AST pass that synthesizes one small
//!     forwarding thunk per distinct top-level function referenced bare
//!     anywhere in the file, shaped exactly like the equivalent hand-written
//!     closure literal (`{ x -> double(x) }`) so it flows through the
//!     existing, already-correct lambda-lifting/closure codegen unchanged.
//!   • #5366 (MSIL) — a function/closure value bound WITHOUT a literal
//!     `(T) -> U` type annotation at its declaration site silently stayed
//!     boxed, corrupting arithmetic performed on its call result with no
//!     exception — including the alias-annotated case (`val f: Handler =
//!     ...` where `alias Handler = (Int) -> Int`) and the fully-inferred
//!     case (`val f = adder(5)` where `adder`'s own declared return type is
//!     the alias `Handler`, not a literal `(Int) -> Int`).  Fixed by
//!     `resolveFuncTypeExprMsil` (`msil/codegen.l`), which follows a
//!     `TRef`-typed annotation/return through `cctx.aliasTargets` down to
//!     its underlying `TFunction` shape at every `funcValRetTypes`/
//!     `fieldFuncRetTypes` registration site (local bindings, params, record
//!     fields, and the same-package-call return-type inference `#5774`
//!     added) — exactly like a literal `(Int) -> Int` annotation already
//!     registered.
//!   • #6393 (JVM) — the same two gaps, JVM-shaped: (1) a bare top-level
//!     function reference had NO codegen path at all (a compile-time panic,
//!     "reference 'name' resolves to no local, ..."), fixed by synthesizing
//!     the equivalent forwarding closure INLINE at the point of use
//!     (`lowerBareFuncRefValue`, `jvm/codegen/02_exprs.l`) — no separate
//!     pre-codegen pass is needed on this target, since a JVM closure is a
//!     synthesised inner class built entirely at the point of use, with no
//!     MethodDef pre-scan to stabilise ahead of codegen; (2) an alias-typed
//!     function annotation (param/return/record-field/local) loaded the
//!     alias name itself as a nonexistent class
//!     (`NoClassDefFoundError: <Pkg>/<AliasName>`), fixed by the same
//!     alias-chain-to-`TFunction` resolution MSIL's `resolveFuncTypeExprMsil`
//!     performs, threaded through `FuncCtx.aliasTargets` to every erasure
//!     site (`jvm/codegen/06_items.l`, `05_stmts.l`).  The eligibility
//!     predicate (#6393's gap 1) and the alias-chain resolver (#6393's gap 2)
//!     are shared between both backends via `Lyric.BareFuncRef`
//!     (`lyric-compiler/lyric/bare_func_ref.l`); the codegen STRATEGY that
//!     consumes them stays backend-specific (a pre-codegen `IFunc`-synthesis
//!     pass on MSIL, an inline `lowerLambda` call on JVM) because the two
//!     targets' closure-construction models are structurally different.
//!
//! Run via native `lyric test` on both targets (wired in `ci.yml`):
//!
//!   lyric test --target dotnet lyric-compiler/lyric/bare_func_ref_self_test.l
//!   lyric test --target jvm lyric-compiler/lyric/bare_func_ref_self_test.l
@test_module
package Lyric.BareFuncRefSelfTest

import Std.Core
import Std.Testing

alias Handler = (Int) -> Int

func double(x: in Int): Int {
  x * 2
}

func triple(x: in Int): Int {
  x * 3
}

func apply(h: in Handler, x: in Int): Int {
  h(x)
}

// #5362 exact repro shape: a bare top-level function name passed directly
// where a function-typed value is expected.
test "bare top-level function passed as a call argument, invoked inside the callee" {
  assertEqualInt(apply(double, 21), 42, "apply(double, 21) == double(21) == 42")
}

// A different bare function, same call site shape — guards against the
// synthesized thunk being keyed wrong and forwarding to the wrong function.
test "a second bare top-level function passed as a call argument" {
  assertEqualInt(apply(triple, 7), 21, "apply(triple, 7) == triple(7) == 21")
}

// #5362's own "named function stored then called through a variable" shape.
func storeThenCall(): Int {
  val f = double
  f(20)
}

test "named function stored in a local, then invoked through the variable" {
  assertEqualInt(storeThenCall(), 40, "val f = double; f(20) == 40")
}

// #5362's record-field variant: a bare function stored as a record field,
// read back into a local, then invoked.
record Holder {
  h: Handler
}

func storeInRecordThenCall(): Int {
  val holder = Holder(h = double)
  val f = holder.h
  f(21)
}

test "bare top-level function stored in a record field, then invoked" {
  assertEqualInt(storeInRecordThenCall(), 42, "Holder(h = double).h invoked with 21 == 42")
}

// #5366: HOF returning a closure through a type ALIAS (not a literal
// `(Int) -> Int`), bound with NO annotation at all — the exact original repro.
func adder(n: in Int): Handler {
  { x: Int -> x + n }
}

func inferredAliasReturnArithmetic(): Int {
  val f = adder(5)
  val r1 = f(10)
  r1 + 1
}

test "unannotated local bound from an alias-returning HOF call, arithmetic on result (#5366)" {
  assertEqualInt(inferredAliasReturnArithmetic(), 16, "adder(5)(10) + 1 == 16")
}

// #5366: same shape, but with an explicit ALIAS-typed annotation (`: Handler`)
// rather than a literal `(Int) -> Int` annotation — also previously un-tracked.
func aliasAnnotatedArithmetic(): Int {
  val f: Handler = adder(5)
  val r1 = f(10)
  r1 + 1
}

test "alias-typed annotated local bound from an alias-returning HOF call, arithmetic on result (#5366)" {
  assertEqualInt(aliasAnnotatedArithmetic(), 16, "adder(5)(10) + 1 == 16 (alias-annotated)")
}

// #5366 via an alias-typed PARAMETER (registerParamsMsil / the lambda-param
// registration site): arithmetic on the call result of an alias-typed
// function value received as a parameter, not just a local.
func applyAndAddOne(h: in Handler, x: in Int): Int {
  h(x) + 1
}

test "alias-typed function parameter, arithmetic on the call result (#5366)" {
  assertEqualInt(applyAndAddOne(double, 10), 21, "double(10) + 1 == 21 via alias-typed param")
}

// #6389 addendum: `collectBareFuncValueRefsExpr`'s `EMatch` case never walked
// `MatchArm.guard`, so a bare top-level function referenced ONLY inside a
// match guard never got a synthesized thunk — reproducing #5362's
// `NullReferenceException` at the guard's `EPath` value read.
func classifyByGuard(n: in Int): Int {
  match n {
    case x if apply(double, x) > 5 -> 42
    case _ -> 0
  }
}

test "bare top-level function referenced only inside a match guard (#6389 addendum)" {
  assertEqualInt(classifyByGuard(5), 42, "apply(double, 5) == 10 > 5, guard selects the first arm")
}

// #6389 addendum: `allReferencedNamesMsil`'s `IRecord` case never walked
// `RMField(field).dflt`, so a bare top-level function referenced ONLY as a
// record field's default value never got a synthesized thunk either.  Reads
// the defaulted field into a local before invoking (mirroring
// `storeInRecordThenCall` above) rather than chain-calling it directly
// (`holder.h(10)`) — that dot-call-chain shape hits a separate, pre-existing
// method-dispatch gap unrelated to this addendum's thunk-synthesis fix.
record GuardHolder {
  h: Handler = double
}

func callViaDefaultedField(): Int {
  val holder = GuardHolder()
  val f = holder.h
  f(10)
}

test "bare top-level function referenced only as a record field default (#6389 addendum)" {
  assertEqualInt(callViaDefaultedField(), 20, "GuardHolder().h defaults to double; double(10) == 20")
}
