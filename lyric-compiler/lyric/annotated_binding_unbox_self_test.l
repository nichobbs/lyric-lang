//! annotated_binding_unbox_self_test.l — regression test for #5519: on
//! `--target dotnet`, binding an UNANNOTATED closure's call result to a
//! local with an EXPLICIT primitive type annotation skipped the `unbox.any`
//! the inference path (`val r = g()`, no annotation) already inserted:
//!
//!   val g = { -> 41 + 1 }
//!   val r: Int = g()   // pre-fix: garbage — the boxed `object` the erased
//!                      // closure-call ABI returns was stored raw into the
//!                      // Int32 slot the annotation declared, no unbox.any.
//!
//! Root cause (`msil/codegen.l`): the `LBVal`/`LBLet`/`LBVar` binding arms
//! all computed `effectiveTy = if annoTy != MObject { annoTy } else { initTy }`
//! and used `effectiveTy` for the slot's declared type, but never coerced the
//! STACK VALUE itself from the call's actual lowered type (`initTy`, `MObject`
//! for an unannotated closure whose return type isn't tracked in
//! `funcValRetTypes`) to the annotation's value type — the fix inserts
//! `coerceCallArgMsil(cctx, insns, initTy, annoTy)` (the same object->valuetype
//! `unbox.any` coercion already used at call-argument boundaries) right after
//! the init expression lowers, whenever `annoTy != MObject and initTy ==
//! MObject`.
//!
//! Covers `val`, `var`, and a `var` later captured by a nested closure (the
//! hoisted heap-cell storage path, `finishHoistedCellMsil`) — all three
//! binding arms plus the hoisted-cell branch of `LBVar` needed the fix.
//!
//! Run via `lyric test lyric-compiler/lyric/annotated_binding_unbox_self_test.l`
//! on both `--target dotnet` and `--target jvm` (mirrors `bitwise_self_test.l`
//! — the JVM backend was never affected, so this also guards against a
//! future regression there).  Imports only `Std.*`.
@test_module
package Lyric.AnnotatedBindingUnboxSelfTest

import Std.Core
import Std.Testing

test "val r: Int = g() unboxes an unannotated closure's erased call result" {
  val g = { -> 41 + 1 }
  val r: Int = g()
  assertEqualInt(r, 42, "val r: Int = g()")
}

test "val r: Long = g() unboxes an unannotated closure's erased call result" {
  val g = { -> 41i64 + 1i64 }
  val r: Long = g()
  assertEqualLong(r, 42i64, "val r: Long = g()")
}

test "val r: Double = g() unboxes an unannotated closure's erased call result" {
  val g = { -> 41.5 + 1.5 }
  val r: Double = g()
  assertTrue(r == 43.0, "val r: Double = g()")
}

test "val r: Bool = g() unboxes an unannotated closure's erased call result" {
  val g = { -> 2 > 1 }
  val r: Bool = g()
  assertTrue(r, "val r: Bool = g()")
}

test "var r: Int = g() unboxes and remains a genuine Int32 slot after mutation" {
  val g = { -> 41 + 1 }
  var r: Int = g()
  assertEqualInt(r, 42, "var r: Int = g()")
  r = r + 1
  assertEqualInt(r, 43, "var r mutated after the unboxed init")
}

test "a closure-captured var r: Int = g() unboxes before the hoisted cell is built" {
  val g = { -> 41 + 1 }
  var r: Int = g()
  // Referencing `r` inside this nested closure forces the by-ref hoisted-cell
  // storage path (`finishHoistedCellMsil`) for `r`'s declaration above.
  val bumpAndRead = { -> r = r + 1; r }
  val after = bumpAndRead()
  assertEqualInt(after, 43, "hoisted var r: Int = g() unboxed before the cell was created")
  assertEqualInt(r, 43, "the outer binding observes the closure's mutation through the shared cell")
}
