//! #1730 regression: a *called* same-package generic function NRE'd in the
//! self-hosted MSIL backend's `lowerFuncMsil`.  The monomorphizer's
//! `specializeFunc` reconstructed the specialised copy's return type with a
//! `match decl.ret { case None -> None; case Some(r) -> Some(...) }` whose arms
//! the bootstrap F# emitter unified to `Option<object>` instead of
//! `Option<TypeExpr>`.  The widened value, stored in the `ret: Option[TypeExpr]`
//! slot, then matched neither `case Some` nor `case None` in codegen (isinst
//! against `Option<TypeExpr>` failed), the match fell through, and `retTy` was
//! left null — an unconditional NRE on every called generic, even the trivial
//! `idv[T](x: T): T`.  Fixed by constructing the specialised return type via a
//! typed `var` + assignment so the type argument stays concrete (D-progress-360).
//!
//! MSIL target only here (run via native `lyric test --target dotnet`);
//! JVM-target parity for same-package generic specialization is tracked in #1707.
@test_module
package Lyric.GenericSpecializationSelfTest

import Std.Core
import Std.Collections
import Std.Testing

// The exact issue-repro: the simplest possible generic, called with Int.
func idv[T](x: in T): T {
  x
}

// A generic with no value-bearing return (`ret = None`), exercising the
// `case None -> {}` arm of the fixed `specializeFunc` so a void specialisation
// still resolves to `MVoid` instead of falling through to a null `retTy`.
func ignoreVal[T](x: in T): Unit {
  ()
}

// A generic with a generic return type, exercising the `Some(...)`
// reconstruction path through a non-trivial substituted `ret`.
func wrapSome[T](x: in T): Option[T] {
  Some(value = x)
}

test "trivial generic idv[Int] returns its argument (the #1730 repro)" {
  assertEqualInt(idv(5), 5, "idv(5) == 5")
}

test "trivial generic idv[String] specialises independently" {
  assertEqual(idv("hi"), "hi", "idv(\"hi\") == \"hi\"")
}

test "void-returning generic specialises without NRE" {
  ignoreVal(7)
  ignoreVal("x")
  assertTrue(true, "void generic specialisation lowered")
}

test "generic returning Option[Int] round-trips its payload" {
  match wrapSome(42) {
    case None -> assertTrue(false, "wrapSome should be Some")
    case Some(v) -> assertEqualInt(v, 42, "wrapSome(42) payload")
  }
}

test "generic returning Option[String] round-trips its payload" {
  match wrapSome("payload") {
    case None -> assertTrue(false, "wrapSome should be Some")
    case Some(v) -> assertEqual(v, "payload", "wrapSome payload")
  }
}

// ── #1745: bare-None match arm type-widening fix ──────────────────────────────
// Before the fix, `case None -> None` in a generic match body widened to
// `Option<object>`, so `specializeFunc` produced a wrong return-arm type and
// the monomorphized copy mis-dispatched at runtime.
func optId[T](x: in Option[T]): Option[T] {
  match x {
    case None -> None
    case Some(v) -> Some(value = v)
  }
}

// The argument is bound to an explicitly-annotated local first so the
// monomorphizer can infer T from the env: a bare `optId(None)` argument
// carries no type evidence, so the call could never specialise — it
// previously compiled anyway because the dangling call to the erased
// generic degenerated to an identity pass-through of the argument (the
// silent miscompile M0002 now rejects, docs/59 §5.2 B2).  These tests
// only ever passed by that accident; with the annotated binding they
// exercise the real #1745 spec-body path.
test "#1745: bare None arm in generic match specialises correctly for Int" {
  val src: Option[Int] = None
  val a = optId(src)
  match a {
    case None -> assertTrue(true, "None -> None (Int)")
    case Some(v) -> assertTrue(false, "expected None")
  }
}

test "#1745: bare Some arm in generic match preserved for Int" {
  val src: Option[Int] = Some(value = 77)
  val a = optId(src)
  match a {
    case None -> assertTrue(false, "expected Some")
    case Some(v) -> assertEqualInt(v, 77, "Some(77) round-trips")
  }
}

test "#1745: bare None arm in generic match specialises correctly for String" {
  val src: Option[String] = None
  val a = optId(src)
  match a {
    case None -> assertTrue(true, "None -> None (String)")
    case Some(v) -> assertTrue(false, "expected None")
  }
}
