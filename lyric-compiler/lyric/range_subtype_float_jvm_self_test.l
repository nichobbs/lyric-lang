//! range_subtype_float_jvm_self_test.l — JVM-only executable regression test
//! for the `Float`-backed `.toFloat()` read-back gap in #6661's own fix.
//!
//! Formerly `range_subtype_unsigned_jvm_self_test.l`: that file also hosted
//! `UInt`/`ULong`-backed range-subtype cases, JVM-only because MSIL had no
//! `UInt`/`ULong` representation at all. Those cases moved to the dual-target
//! `range_subtype_self_test.l` once #6756 gave MSIL a real `UInt`/`ULong`
//! erasure (`typeExprToMsilCtx`'s `UInt -> MInt` / `ULong -> MLong`, mirroring
//! the JVM backend's identical erasure) plus unsigned-aware bounds checking.
//! Renamed since only the JVM-only `Float` case remains here.
//!
//! `type Ratio = Float range 0.0 ..= 1.0` — `Jvm.Lowering.jvmDistinctConvName`
//! gained a real bytecode-level bounds check for `JFloat`
//! (`emitJvmDistinctBoundsToFail`) as part of #6661's fix but had NO `JFloat`
//! case of its own, so `lowerDistinctType` never emitted (or registered,
//! `collectFileSigsSeeded`'s `IDistinctType` arm) any projection method for a
//! `Float`-backed distinct type at all — `Weight`
//! (`range_subtype_self_test.l`) could be CONSTRUCTED via `from`/`tryFrom` but
//! never READ BACK. JVM-only (unlike `SmallByte`'s `.toInt()`/no-assertion
//! split in `range_subtype_self_test.l`): MSIL erases `Float` to `MDouble` in
//! scalar position (`Msil.Lowering.distinctConvName` names its accessor
//! `"toDouble"`), so `.toFloat()` does not exist as a call there.
//!
//!   lyric test --target jvm lyric-compiler/lyric/range_subtype_float_jvm_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.RangeSubtypeFloatJvmSelfTest

import Std.Core
import Std.Testing

type Ratio = Float range 0.0 ..= 1.0

test "Float-backed range subtype: toFloat() projects the wrapped value back (jvmDistinctConvName)" {
  assertTrue(Ratio.from(0.25f32).toFloat() > 0.2499f32, "from(0.25).toFloat() round-trips (lower)")
  assertTrue(Ratio.from(0.25f32).toFloat() < 0.2501f32, "from(0.25).toFloat() round-trips (upper)")
  assertTrue(Ratio.from(0.0f32).toFloat() == 0.0f32, "lower bound round-trips exactly")
  assertTrue(Ratio.from(1.0f32).toFloat() == 1.0f32, "upper bound round-trips exactly")
}
