//! range_subtype_unsigned_jvm_self_test.l — JVM-only executable regression
//! test for `UInt`/`ULong`-backed distinct/range subtype construction
//! (#6661), plus the `Float`-backed `.toFloat()` read-back this file also
//! hosts (JVM-only for the same reason: the conversion-method name is
//! per-backend, see the header comment on that test below).
//!
//! Split out of `range_subtype_self_test.l` (which runs on BOTH
//! `--target dotnet` and `--target jvm`) because `UInt`/`ULong` have NO MSIL
//! representation at all: `Msil.Codegen.typeExprToMsilCtx` has no `UInt`/
//! `ULong` arm (unlike `Float`, which erases to `MDouble` there), so a
//! `UInt`/`ULong`-backed distinct type falls through to "user type in this
//! package" (`MClass`) on `--target dotnet` and crashes the CLR loader with
//! "Common Language Runtime detected an invalid program" at run time.
//! Extending MSIL with a real `UInt`/`ULong` representation is a separate,
//! larger, cross-cutting change (`typeExprToMsilCtx` is consulted for every
//! scalar position, not just range-subtype underlying types) — tracked
//! separately, out of scope for #6661, which is specifically about the JVM
//! backend's range-subtype lowering.
//!
//! On JVM, `UInt`/`ULong` erase to the same two's-complement `int`/`long` a
//! signed `Int`/`Long` of the same width uses (`Jvm.Codegen.typeExprToJvm`,
//! #6661).  Before the fix: (1) `typeExprToJvm` had NO `UInt`/`ULong` arm at
//! all, so a `UInt`/`ULong`-backed distinct type's underlying representation
//! fell through to "user type in this package" — a nonexistent class,
//! `NoClassDefFoundError`/verification failure at class-load; and (2) even
//! with a representation, a bound or an in-range value at/above 2^31
//! (`UInt`) reads as NEGATIVE under a plain signed comparison
//! (`if_icmpxx`), so `Jvm.Lowering.emitJvmDistinctBoundsToFail` now
//! dispatches to `Integer.compareUnsigned`/`Long.compareUnsigned` instead
//! whenever `LDistinctType.isUnsigned` is set.
//!
//!   lyric test --target jvm lyric-compiler/lyric/range_subtype_unsigned_jvm_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.RangeSubtypeUnsignedJvmSelfTest

import Std.Core
import Std.Testing

// `UInt` (32-bit unsigned, docs/01 §2.1: `0 ..= 4_294_967_295`).  `1000` and
// `4000000000` are both genuinely IN RANGE but `4000000000` (and the
// `2500000000` test value below) carry the sign bit when read as a signed
// 32-bit int — before the fix, a signed comparison would misreport them as
// "less than min" (`Err`), the actual silent-miscompile #6661 flags, not
// merely a verifier failure.
type Population = UInt range 1000 ..= 4000000000

func populationIsOk(r: in Result[Population, String]): Bool {
  match r {
    case Ok(_) -> true
    case Err(_) -> false
  }
}

test "UInt-backed range subtype: values with the sign bit set are still in range (#6661)" {
  assertTrue(populationIsOk(Population.tryFrom(1000u32)), "1000 lower bound inclusive")
  assertTrue(
    populationIsOk(Population.tryFrom(2500000000u32)),
    "2500000000 (>2^31, in range) must not read as negative"
  )
  assertTrue(populationIsOk(Population.tryFrom(4000000000u32)), "4000000000 upper bound inclusive (>2^31)")
  assertFalse(populationIsOk(Population.tryFrom(999u32)), "999 below lower bound")
  assertFalse(populationIsOk(Population.tryFrom(4000000001u32)), "4000000001 above upper bound (>2^31)")
}

func populationValue(r: in Result[Population, String]): Int {
  match r {
    case Ok(p) -> p.toInt()
    case Err(_) -> -1
  }
}

test "UInt-backed range subtype: toInt() projection round-trips for a small value (#6661)" {
  assertEqualInt(populationValue(Population.tryFrom(5000u32)), 5000, "tryFrom(5000).toInt() round-trips")
}

// `ULong` (64-bit unsigned) — before the fix this had NO JVM representation
// at all (`typeExprToJvm` fell through to a nonexistent same-package
// class), so this pins basic construction working end-to-end.  A bound
// exercising the sign bit would need to exceed `Long.MAX_VALUE`
// (9223372036854775807), which the shared Int64-based range-literal fold
// (`foldRangeBoundJvm`) cannot represent — same pre-existing limitation the
// `Long`-backed `Cents` case in `range_subtype_self_test.l` lives with,
// orthogonal to #6661.
type BigId = ULong range 0 ..= 9000000000000000000

func bigIdIsOk(r: in Result[BigId, String]): Bool {
  match r {
    case Ok(_) -> true
    case Err(_) -> false
  }
}

test "ULong-backed range subtype: construction and bounds (#6661)" {
  assertTrue(bigIdIsOk(BigId.tryFrom(0u64)), "0 lower bound inclusive")
  assertTrue(bigIdIsOk(BigId.tryFrom(123456789012345u64)), "a large in-range value")
  assertTrue(bigIdIsOk(BigId.tryFrom(9000000000000000000u64)), "9000000000000000000 upper bound inclusive")
  assertEqualLong(BigId.from(42u64).toLong(), 42i64, "from(42).toLong() round-trips")
}

// `Float`-backed distinct/range subtype `.toFloat()` read-back — a followup
// gap in #6661's own fix: `Jvm.Lowering.jvmDistinctConvName` gained a real
// bytecode-level bounds check for `JFloat` (`emitJvmDistinctBoundsToFail`)
// but had NO `JFloat` case of its own, so `lowerDistinctType` never emitted
// (or registered, `collectFileSigsSeeded`'s `IDistinctType` arm) any
// projection method for a `Float`-backed distinct type at all — `Weight`
// (`range_subtype_self_test.l`) could be CONSTRUCTED via `from`/`tryFrom` but
// never READ BACK. JVM-only (unlike `SmallByte`'s `.toInt()`/no-assertion
// split above): MSIL erases `Float` to `MDouble` in scalar position
// (`Msil.Lowering.distinctConvName` names its accessor `"toDouble"`), so
// `.toFloat()` does not exist as a call there.
type Ratio = Float range 0.0 ..= 1.0

test "Float-backed range subtype: toFloat() projects the wrapped value back (jvmDistinctConvName)" {
  assertTrue(Ratio.from(0.25f32).toFloat() > 0.2499f32, "from(0.25).toFloat() round-trips (lower)")
  assertTrue(Ratio.from(0.25f32).toFloat() < 0.2501f32, "from(0.25).toFloat() round-trips (upper)")
  assertTrue(Ratio.from(0.0f32).toFloat() == 0.0f32, "lower bound round-trips exactly")
  assertTrue(Ratio.from(1.0f32).toFloat() == 1.0f32, "upper bound round-trips exactly")
}
