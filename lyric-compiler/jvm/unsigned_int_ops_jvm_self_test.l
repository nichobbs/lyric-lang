//! unsigned_int_ops_jvm_self_test.l — JVM-only regression test for #6748:
//! `UInt`/`ULong` comparison/division/remainder/stringification outside the
//! range-subtype bounds-check path.
//!
//! #6661/#6695 gave the JVM backend proper `UInt`/`ULong` type-erasure
//! handling: `isPrimitiveTypeKeyword` reserves them, `typeExprToJvm` erases
//! them to `JInt`/`JLong`, and `Jvm.Lowering.emitJvmDistinctBoundsToFail`
//! (the range-subtype `from`/`tryFrom` bounds check) dispatches to
//! `Integer`/`Long.compareUnsigned` whenever `LDistinctType.isUnsigned` is
//! set. But that bounds check is internal plumbing for range-subtype
//! construction — ordinary user code comparing (`<`/`<=`/`>`/`>=`), dividing
//! (`/`), taking the remainder (`%`), or stringifying (`.toString()`, string
//! interpolation, `+` concatenation) a plain `UInt`/`ULong` VALUE still went
//! through the native SIGNED `if_icmpxx`/`lcmp`/`idiv`/`ldiv`/`irem`/`lrem`/
//! `String.valueOf` those types erase to — silently WRONG whenever the value
//! has its sign bit set (`UInt` >= 2^31, `ULong` >= 2^63), since the JVM has
//! no unsigned integer primitive at all. This file pins the fix: `Jvm.Codegen`
//! now tracks which locals/parameters/literals are statically `UInt`/`ULong`
//! (`FuncCtx.unsignedVars`, `isUnsignedExpr`) and dispatches relational
//! comparison, `/`, `%`, and stringification through `Integer`/
//! `Long.compareUnsigned`/`divideUnsigned`/`remainderUnsigned`/
//! `toUnsignedString` for exactly those operands, leaving plain `Int`/`Long`
//! on the native signed opcodes.
//!
//! `UInt`/`ULong` have no MSIL representation at all (docs/44,
//! `range_subtype_unsigned_jvm_self_test.l`'s header), so this file — like
//! that one — is JVM-only.
//!
//!   lyric test --target jvm lyric-compiler/jvm/unsigned_int_ops_jvm_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Jvm.UnsignedIntOpsJvmSelfTest

import Std.Core
import Std.Testing

// ── UInt: comparison ─────────────────────────────────────────────────────────
//
// `3_000_000_000` and `1_000_000_000` are both valid `UInt` values (range
// `0 ..= 4_294_967_295`), but `3_000_000_000` carries the sign bit as a
// signed 32-bit int (`3_000_000_000 - 2^32 = -1_294_967_296`), so a plain
// signed `if_icmplt`/`if_icmpgt` would report `a < b` as TRUE and `a > b` as
// FALSE — backwards.
test "UInt relational comparison is unsigned across the sign bit (#6748)" {
  val a: UInt = 3000000000u32
  val b: UInt = 1000000000u32
  assertTrue(a > b, "3_000_000_000 > 1_000_000_000 (unsigned)")
  assertFalse(a < b, "3_000_000_000 < 1_000_000_000 must be false (unsigned)")
  assertTrue(a >= b, "a >= b")
  assertFalse(a <= b, "a <= b must be false")
  assertTrue(b < a, "1_000_000_000 < 3_000_000_000 (unsigned)")
  assertFalse(b > a, "b > a must be false")
}

test "UInt equality is unaffected (sanity check) (#6748)" {
  val a: UInt = 3000000000u32
  val c: UInt = 3000000000u32
  assertTrue(a == c, "equal UInt values compare equal")
  assertFalse(a != c, "equal UInt values are not unequal")
}

// A `UInt` PARAMETER (not just a local) must get the same treatment —
// exercises `setupStaticParamSlotsAndHolders`'s `recordUnsignedVarTy` call.
func uintGreater(x: in UInt, y: in UInt): Bool {
  x > y
}

test "UInt comparison inside a function parameter (#6748)" {
  assertTrue(uintGreater(3000000000u32, 1000000000u32), "param-typed UInt comparison is unsigned")
  assertFalse(uintGreater(1000000000u32, 3000000000u32), "reversed args correctly false")
}

// ── UInt: division / remainder ───────────────────────────────────────────────
//
// Signed `idiv`/`irem` on the same sign-bit-set bit pattern computes the
// WRONG quotient/remainder (Java's `idiv` truncates toward zero on the
// NEGATIVE interpretation of the bits).
test "UInt division and remainder are unsigned across the sign bit (#6748)" {
  val a: UInt = 3000000000u32
  val two: UInt = 2u32
  val seven: UInt = 7u32
  assertTrue((a / two) == 1500000000u32, "3_000_000_000 / 2 == 1_500_000_000 (unsigned)")
  assertTrue((a % seven) == 4u32, "3_000_000_000 % 7 == 4 (unsigned)")
}

// ── UInt: toString / interpolation / concatenation ───────────────────────────
//
// `String.valueOf(int)` on the signed bit pattern of `3_000_000_000` prints
// "-1294967296" — the exact silent miscompile this ticket describes.
test "UInt toString renders the unsigned decimal value (#6748)" {
  val a: UInt = 3000000000u32
  assertEqual(a.toString(), "3000000000", "member .toString() is unsigned")
  assertEqual(toString(a), "3000000000", "free toString(x) is unsigned")
}

test "UInt string interpolation renders the unsigned decimal value (#6748)" {
  val a: UInt = 3000000000u32
  assertEqual("value=${a}", "value=3000000000", "interpolation is unsigned")
}

test "UInt string concatenation renders the unsigned decimal value (#6748)" {
  val a: UInt = 3000000000u32
  assertEqual("value=" + a.toString(), "value=3000000000", "+ concatenation is unsigned")
}

// ── ULong: comparison ─────────────────────────────────────────────────────────
//
// A `ULong` literal is folded through the lexer's signed `Int64` field
// (`Lyric.Lexer.LInt.value: Long`), so no LITERAL can directly express a
// value at or above `2^63` (the same limitation
// `range_subtype_unsigned_jvm_self_test.l`'s `BigId` header documents) —
// `a` is built via `ULong` ADDITION instead (`ladd` wraps identically for
// signed and unsigned two's-complement, so this is a faithful way to reach
// a sign-bit-set `ULong` value at runtime): `Long.MAX_VALUE + 4 == 2^63 + 3`,
// which reads as a large NEGATIVE number under a signed 64-bit
// interpretation, so the same class of bug applies to `lcmp`/`ldiv`/`lrem`.
test "ULong relational comparison is unsigned across the sign bit (#6748)" {
  val base: ULong = 9223372036854775807u64
  val a: ULong = base + 4u64
  val b: ULong = 1000000000000000000u64
  assertTrue(a > b, "2^63+3 > 1e18 (unsigned) — a signed read of a is deeply negative")
  assertFalse(a < b, "2^63+3 < 1e18 must be false (unsigned)")
  assertTrue(a >= b, "a >= b")
  assertFalse(a <= b, "a <= b must be false")
}

// ── ULong: division / remainder ───────────────────────────────────────────────
test "ULong division and remainder are unsigned across the sign bit (#6748)" {
  val base: ULong = 9223372036854775807u64
  val a: ULong = base + 4u64
  val two: ULong = 2u64
  val three: ULong = 3u64
  assertTrue((a / two) == 4611686018427387905u64, "(2^63+3) / 2 (unsigned)")
  assertTrue((a % two) == 1u64, "(2^63+3) % 2 == 1 (unsigned)")
  assertTrue((a / three) == 3074457345618258603u64, "(2^63+3) / 3 (unsigned)")
  assertTrue((a % three) == 2u64, "(2^63+3) % 3 == 2 (unsigned)")
}

// ── ULong: toString / interpolation ───────────────────────────────────────────
test "ULong toString renders the unsigned decimal value (#6748)" {
  val base: ULong = 9223372036854775807u64
  val a: ULong = base + 4u64
  assertEqual(a.toString(), "9223372036854775811", "member .toString() is unsigned")
  assertEqual(toString(a), "9223372036854775811", "free toString(x) is unsigned")
}

test "ULong string interpolation renders the unsigned decimal value (#6748)" {
  val base: ULong = 9223372036854775807u64
  val a: ULong = base + 4u64
  assertEqual("value=${a}", "value=9223372036854775811", "interpolation is unsigned")
}
