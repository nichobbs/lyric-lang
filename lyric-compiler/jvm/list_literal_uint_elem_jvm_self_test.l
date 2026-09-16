//! list_literal_uint_elem_jvm_self_test.l — CI gate for `Jvm.Codegen.
//! listLiteralElemTypeJvm`'s `U16`/`U32`/`U64` coverage (#6741 SUGGESTION,
//! `codegen/02_exprs.l`).
//!
//! `listLiteralElemTypeJvm` peeks a list-literal element's static type for
//! `inferHomogeneousListElemTypeJvm`'s homogeneity fast path (#5686/#6661):
//! an unannotated `val xs = [a, b]` whose elements share one simple numeric/
//! String type records that type against `xs` (`recordVarGenericArgs`), so a
//! later `xs[i]` narrows from erased `Object` to the real element type
//! instead of staying erased.
//!
//! Before this fix, `listLiteralElemTypeJvm`'s `LInt` match had arms for
//! `I8`/`U8`/`NoIntSuffix`/`I16`/`I32`/`I64` but fell through to the `_ ->
//! JRef("java/lang/Object")` sentinel for `U16`/`U32`/`U64` — inconsistent
//! with this repo's own `isExplicit32OrNarrower` int-push table (`lowerExpr`,
//! same file) and `Lyric.TypeChecker`'s literal-suffix table
//! (`typechecker_exprs.l`: `U16`/`U32 -> UInt`, `U64 -> ULong`), both of
//! which treat every one of these suffixes as a definite, single concrete
//! type. A `u16`/`u32`/`u64`-suffixed unannotated list literal therefore
//! never qualified for the homogeneity fast path: `isSimpleListElemJvm`
//! rejected the `Object` sentinel, so `inferHomogeneousListElemTypeJvm`
//! returned `None`, `xs`'s element type stayed unrecorded, and `xs[i]` read
//! back erased `Object` — a following arithmetic op on it hard-failed
//! (verification/build-time, not a silent miscompile) since `Object` has no
//! numeric opcode.
//!
//! JVM-only: this fixes a JVM-backend-only codegen helper
//! (`Jvm.Codegen.listLiteralElemTypeJvm`) with no MSIL counterpart — this
//! file exercises the JVM lowering specifically (`Jvm.ListLiteralUintElem-
//! JvmSelfTest`, `lyric-compiler/jvm/`). MSIL's own list-literal homogeneity
//! inference (`listLiteralElemTypeMsil`, `msil/codegen.l`) had a separate,
//! now-fixed `U16`/`U32`/`U64` gap (#6782, fixed alongside #6756's MSIL
//! `UInt`/`ULong` representation) — its regression coverage lives in the
//! dual-target `lyric-compiler/lyric/list_literal_index_self_test.l`
//! instead of being folded into this JVM-directory file.
//!
//!   lyric test --target jvm lyric-compiler/jvm/list_literal_uint_elem_jvm_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Jvm.ListLiteralUintElemJvmSelfTest

import Std.Testing

test "unannotated U16 list literal elements infer for indexed arithmetic (#6741 SUGGESTION)" {
  val xs = [1u16, 2u16]
  assertTrue(xs[0] + xs[1] == 3u16, "u16 list literal elements widen correctly for indexed arithmetic")
}

test "unannotated U32 list literal elements infer for indexed arithmetic (#6741 SUGGESTION)" {
  val xs = [100000u32, 1u32]
  assertTrue(xs[0] + xs[1] == 100001u32, "u32 list literal elements widen correctly for indexed arithmetic")
}

test "unannotated U64 list literal elements infer for indexed arithmetic (#6741 SUGGESTION)" {
  val xs = [1000000000000u64, 1u64]
  assertTrue(xs[0] + xs[1] == 1000000000001u64, "u64 list literal elements widen correctly for indexed arithmetic")
}
