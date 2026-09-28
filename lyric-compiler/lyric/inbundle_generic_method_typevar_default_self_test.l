//! inbundle_generic_method_typevar_default_self_test.l — dual-target runtime
//! regression test for `pushDefaultValueMsil` seeding a real (unerased)
//! in-bundle generic type parameter `T` with `ldnull` instead of `default(T)`
//! (#7525).
//!
//! On `--target dotnet`, a method declared *inside* a generic record body
//! (`lowerRecordMethodMsil`, docs/43) keeps its own type parameter `T` as a
//! real CLR generic parameter (`MTypeVar` / `!0`) all the way to codegen —
//! unlike a generic top-level FUNCTION, which the monomorphizer specialises
//! (or, when that doesn't apply, `Msil.Codegen` erases `T` to `object`,
//! #2557). A method whose declared return is `T` and whose body is a bare
//! `: Never`-typed tail expression (`panic(...)`, no surrounding `if`) needs
//! a zero/default value pushed onto the stack before the trailing `ret`, so
//! the (dead, unreachable-at-runtime) instruction sequence still satisfies
//! the CLR's "something on the stack at `ret`" requirement — see
//! `lowerMethodBodyTailMsil`'s `pushDefaultValueMsil(cctx, fctx, insns, retTy)`
//! call for the `FBExpr` case. Before this fix, `pushDefaultValueMsil`'s
//! catch-all arm emitted `ldnull` for ANY type it didn't special-case,
//! including a bare `MTypeVar` — invalid IL for a value-type instantiation of
//! `T` (`ldnull` requires a type known to be a reference type; an
//! unconstrained generic parameter is not, and unlike a REFERENCE-type
//! instantiation — which the CLR JITs once as shared "canonical" code where
//! `!0` really is `object` — a VALUE-type instantiation such as `Int` gets
//! its own JIT compilation where `!0` is genuinely `int32`, and the bogus
//! `ldnull` there crashed with `BadImageFormatException` at JIT time, not
//! merely returning a wrong value).
//!
//! The fix adds an `MTypeVar` arm to `pushDefaultValueMsil` that mints a
//! `VAR(n)` TypeSpec (the same by-name VAR-TypeSpec idiom
//! `boxForUnionEqualityMsil` already uses for `box`) and emits `initobj`
//! against it, mirroring the existing `MValueTypeRef`/`MValueTypeGenericInst`
//! arms. Applying that fix in isolation surfaced a SECOND, previously
//! unreachable bug it depends on: `allocSlotMsil` is used to allocate the
//! temporary local `initobj` writes through, and
//! `Msil.Lowering.buildLocalVarSig`/`buildLocalVarSigWithCtx` (the
//! `.locals init (...)` signature blob encoders) had no `MTypeVar` arm —
//! their catch-all fell back to `elementTypeByte`, which (by its own doc
//! comment) returns only the VAR/MVAR PREFIX byte and relies on the caller to
//! append the trailing index byte the way `bufMsilType` does; the local-sig
//! catch-all never did, truncating the blob (`ilverify`: "Unable to resolve
//! token"; observed directly via `System.Reflection.Metadata` while fixing
//! this issue — the LocalVarSig blob was 3 bytes `[07,01,13]`, VAR with the
//! index byte silently missing). No source shape reached a `T`-typed LOCAL
//! before this fix — record/union/field encodings all resolve `T` through
//! ctx-aware signature paths that already handled `MTypeVar` correctly — so
//! this was latent and untriggered until `pushDefaultValueMsil`'s new arm
//! became the first caller to allocate one. Both are fixed together (#7525).
//!
//! `Box[T].alwaysPanic()` below is the load-bearing case: its body is
//! *unconditionally* `panic(...)`, so `exprTailTy == MVoid` on every call and
//! `pushDefaultValueMsil` always runs for that MethodDef (once per TypeDef —
//! the method body is shared IL across every closed instantiation, so this
//! does not need to be repeated per-`T`; the interesting per-instantiation
//! axis is only at the JIT/verifier level, and `Box[Int]` specifically pins
//! the value-type-instantiation class that crashed before the fix).
//! `Box[T].getOrPanic` (an `if`/`else` whose non-panicking branch returns
//! `self.value`) is a baseline/parity check across representation classes —
//! value type (`Int`), reference type (`String`), and an in-bundle record
//! (`Pair`) — that ordinary generic-record-method returns of `T` still work
//! correctly after this fix (an `EIf`'s own branch-unification codegen turns
//! out to have a separate mechanism from `pushDefaultValueMsil` and does not
//! itself allocate a `T`-typed local, confirmed by inspecting the emitted
//! `.locals` signature).
//!
//! `--target jvm` has no analogous bug: `Jvm.Codegen` always erases a
//! generic-record type parameter to `Object` (never a reified `!0`), and a
//! JVM local's default (`null`/`0`/`false`) is unconditionally valid for an
//! erased `Object` slot — this file's JVM run is a parity/regression guard,
//! not a load-bearing check for this bug.
//!
//! NOT covered here: a closure capturing an uninitialised `var x: T` inside
//! a generic record/impl method — the shape #7525 originally asked for, and
//! the shape that would otherwise most directly exercise the ORIGINAL
//! report's hoisted-cell-seeding call site (`lowerStmtMsil`'s `LBVar`/`None`
//! arm, not the `pushDefaultValueMsil` call sites this file exercises).
//! Discovered while investigating #7525: `lowerRecordMethodMsil` and
//! `lowerImplMethodMsil` never run the by-reference closure-capture pre-pass
//! (`collectInLambdaNamesBlock`/`Expr` into `fctx.hoistedVarNames`) that
//! `lowerFuncMsilScoped` runs for top-level functions and lifted lambdas —
//! so ANY closure inside ANY record/impl method (generic or not, `var`
//! initialised or not) that captures a `var` local fails to build today with
//! "Msil.Codegen: internal error — captured mutable (`var`) local … was not
//! hoisted to a heap cell (#1479 v2 closure-capture pre-pass missed it)".
//! That is a distinct, broader pre-existing gap (not introduced or widened by
//! this fix) tracked separately; a closure-based version of this test cannot
//! be written until it lands.
//!
//! Run via `lyric test`, compiled in-process on both targets:
//!
//!   lyric test --target dotnet lyric-compiler/lyric/inbundle_generic_method_typevar_default_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/inbundle_generic_method_typevar_default_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.InbundleGenericMethodTypevarDefaultSelfTest

import Std.Core
import Std.Testing

record Pair {
  a: Int
  b: String
}

// A generic record whose own methods return `T`: `alwaysPanic` is a bare
// Never-typed tail (the load-bearing case, see the file header), and
// `getOrPanic` is an `if`/`else` whose live branch returns the field value
// (the baseline/parity case).
record Box[T] {
  value: T
  func alwaysPanic(): T = panic("Box.alwaysPanic")
  func getOrPanic(fail: in Bool): T = if fail { panic("Box.getOrPanic: fail=true") } else { self.value }
}

test "Box[Int].alwaysPanic panics rather than returning garbage" {
  val b = Box(value = 42)
  assertPanics("Box[Int].alwaysPanic", { -> val _ = b.alwaysPanic() })
}

test "Box[String].alwaysPanic panics rather than returning garbage" {
  val b = Box(value = "hello")
  assertPanics("Box[String].alwaysPanic", { -> val _ = b.alwaysPanic() })
}

test "Box[Pair].alwaysPanic panics rather than returning garbage" {
  val b = Box(value = Pair(a = 7, b = "seven"))
  assertPanics("Box[Pair].alwaysPanic", { -> val _ = b.alwaysPanic() })
}

test "Box[Int].getOrPanic returns the field value on the non-panicking branch" {
  val b = Box(value = 42)
  assertEqualInt(b.getOrPanic(false), 42, "Box[Int].getOrPanic(false)")
}

test "Box[String].getOrPanic returns the field value on the non-panicking branch" {
  val b = Box(value = "hello")
  assertEqual(b.getOrPanic(false), "hello", "Box[String].getOrPanic(false)")
}

test "Box[Pair].getOrPanic returns the field value on the non-panicking branch" {
  val b = Box(value = Pair(a = 7, b = "seven"))
  val p = b.getOrPanic(false)
  assertEqualInt(p.a, 7, "Box[Pair].getOrPanic(false).a")
  assertEqual(p.b, "seven", "Box[Pair].getOrPanic(false).b")
}
