//! bare_func_ref_self_test.l — dotnet-only regression test for #5362 and #5366.
//!
//! Both issues are the same subsystem: how the self-hosted MSIL backend
//! materializes and types a function-typed VALUE outside the strongly-typed-
//! lambda happy path (the closure-class ABI, docs/52/53, Epic #1877/D113).
//!
//!   • #5362 — a bare top-level named function used directly as a
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
//!   • #5366 — a function/closure value bound WITHOUT a literal
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
//!
//! ## Why dotnet-only
//!
//! Both fixes live entirely in `msil/codegen.l` / `msil/bridge.l`. JVM does
//! NOT share either defect in a form this fix addresses:
//!
//!   • #5362's bare-function-reference shape does not compile at all on
//!     `--target jvm` today — a *different*, earlier failure
//!     (`Jvm.Codegen: reference 'name' resolves to no local, parameter,
//!     receiver field, ...`), a compile-time hard crash rather than the MSIL
//!     runtime `NullReferenceException`. This is a materially larger,
//!     separate JVM front-end gap (the JVM backend has no code path for a
//!     bare function-value reference at all), out of scope here — see #5362
//!     for JVM tracking.
//!   • #5366's alias-typed function-return/annotation shape ALSO fails on
//!     `--target jvm` today, but with yet another different failure
//!     (`java.lang.NoClassDefFoundError: <Pkg>/<AliasName>` — the JVM
//!     backend tries to load the alias name itself as a class), for BOTH the
//!     alias-annotated and the fully-inferred variant. This is a distinct,
//!     JVM-only alias-to-function-type resolution bug, not the MSIL
//!     "boxed-and-never-unboxed" defect this test pins — out of scope here.
//!
//! JVM's LITERAL (non-aliased) `(T) -> U`-annotated / same-package-call-
//! inferred cases are already covered dual-target by
//! `func_val_local_rettype_self_test.l` (#5774/#5796) and remain unaffected.
//!
//! Run via native `lyric test --target dotnet` (wired in `ci.yml`):
//!
//!   lyric test --target dotnet lyric-compiler/lyric/bare_func_ref_self_test.l
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
