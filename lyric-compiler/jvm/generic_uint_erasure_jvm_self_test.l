//! generic_uint_erasure_jvm_self_test.l — JVM-only regression test for #6695:
//! `UInt`/`ULong` missing from `Jvm.Codegen.isPrimitiveTypeKeyword`.
//!
//! Same choke-point bug class as #5843/#6660 (fixed for the bare `Object`
//! marker in `c27e023`, D-progress-834): when a generic container is
//! instantiated over `UInt`/`ULong` (`List[UInt]`, `Option[UInt]`, …), the
//! bare type-argument name reaches `eagerlyResolveGenericArg` (`01_types.l`)
//! for pre-resolution into a function's `retGenericArgs`
//! (`eagerlyResolveGenericArgs`, `06_items.l`) or a `resolveConcreteTypeExpr`
//! match-site lookup (`03_match.l`). Before this fix, `isPrimitiveTypeKeyword`
//! had no `UInt`/`ULong` case, so `eagerlyResolveGenericArg` took its
//! non-primitive `else` branch — the ONLY branch that rewrites a bare `TRef`
//! into a same-package class-name marker — and guessed a phantom class
//! (`<pkg>/UInt`), even though `Jvm.Codegen.typeExprToJvm` has correctly
//! erased `UInt`/`ULong` to `JInt`/`JLong` since #6661. A later `checkcast`/
//! `instanceof` against that resolved-but-phantom class then threw
//! `NoClassDefFoundError` at class-load time — the value itself was never
//! unsound, only the generic-arg BOOKKEEPING used to read it back.
//!
//! JVM-only: this pins a defect specific to `Jvm.Codegen`'s own generic-arg
//! bookkeeping choke point (`eagerlyResolveGenericArg`'s non-primitive
//! `else` branch guessing a phantom class name). MSIL now has a real
//! `UInt`/`ULong` representation too (`Msil.Codegen.typeExprToMsilCtx`'s
//! `UInt -> MInt` / `ULong -> MLong` erasure, #6756), but MSIL's generics
//! are real (not type-erased the way the JVM backend's are), so this
//! specific choke-point bug class has no MSIL analog to test.
//!
//!   lyric test --target jvm lyric-compiler/jvm/generic_uint_erasure_jvm_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Jvm.GenericUIntErasureJvmSelfTest

import Std.Core
import Std.Collections
import Std.Testing

// ── List[UInt] / List[ULong] ─────────────────────────────────────────────────
func makeUIntList(): List[UInt] {
  val l: List[UInt] = newList()
  l.add(10u32)
  // >2^31: exercises the same sign-bit hazard `range_subtype_unsigned_jvm_
  // self_test.l` pins for range-subtype bounds, here for a plain list element.
  l.add(2500000000u32)
  l.add(4000000000u32)
  l
}

test "List[UInt] add/index/count round-trips without a phantom class (#6695)" {
  val l = makeUIntList()
  assertEqualInt(l.count, 3, "three elements added")
  assertTrue(l[0] == 10u32, "index 0 preserved")
  assertTrue(l[1] == 2500000000u32, "index 1 (>2^31) preserved")
  assertTrue(l[2] == 4000000000u32, "index 2 (>2^31) preserved")
}

func makeULongList(): List[ULong] {
  val l: List[ULong] = newList()
  l.add(0u64)
  l.add(9000000000000000000u64)
  l
}

test "List[ULong] add/index round-trips without a phantom class (#6695)" {
  val l = makeULongList()
  assertEqualInt(l.count, 2, "two elements added")
  assertTrue(l[0] == 0u64, "index 0 preserved")
  assertTrue(l[1] == 9000000000000000000u64, "index 1 preserved")
}

// ── Option[UInt] / Option[ULong] ─────────────────────────────────────────────
//
// `makeSomeUInt`/`makeNoneUInt` returning `Option[UInt]` is the headline
// repro shape: the function signature's `retGenericArgs` pre-resolves `UInt`
// via `eagerlyResolveGenericArg` at REGISTRATION time (`06_items.l`), and the
// consuming `match` at the call site reads that resolved marker back via
// `resolveConcreteTypeExpr` to pick the `Some`/`None` case correctly — the
// exact two-sided round trip #6695 breaks.
func makeSomeUInt(v: UInt): Option[UInt] {
  Some(value = v)
}

func makeNoneUInt(): Option[UInt] {
  None
}

test "Option[UInt] Some round-trips through match (#6695)" {
  val o = makeSomeUInt(4000000000u32)
  match o {
    case Some(v) -> assertTrue(v == 4000000000u32, "Some payload preserved (>2^31)")
    case None -> assertTrue(false, "expected Some")
  }
}

test "Option[UInt] None round-trips through match (#6695)" {
  val o = makeNoneUInt()
  match o {
    case None -> assertTrue(true, "None correctly matched")
    case Some(_) -> assertTrue(false, "expected None")
  }
}

func makeSomeULong(v: ULong): Option[ULong] {
  Some(value = v)
}

test "Option[ULong] Some round-trips through match (#6695)" {
  val o = makeSomeULong(9000000000000000000u64)
  match o {
    case Some(v) -> assertTrue(v == 9000000000000000000u64, "Some payload preserved")
    case None -> assertTrue(false, "expected Some")
  }
}
