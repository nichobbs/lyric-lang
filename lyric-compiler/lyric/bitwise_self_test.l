// bitwise_self_test.l — first executable regression test for a
// *self-hosted-only* language feature: the bitwise integer methods
// `.and` / `.or` / `.xor` / `.shl` / `.shr` (#1610).
//
// Why this lives here and not in `lyric-stdlib/tests/*_tests.l`:
// those `_tests.l` files are compiled and run by the **F# stage-0**
// emitter (`Lyric.Emitter.Emitter` via `EmitTestKit.compileAndRun`),
// whose parser never learned keyword-named methods — `x.xor(y)` fails
// there with `P0081: expected an identifier after '.'`.  Bitwise ops
// exist only in the self-hosted compiler, so the test program itself
// must be compiled by the self-hosted pipeline.  This file is run by
// the native `lyric test` (issue #1611):
//
//   lyric test lyric-compiler/lyric/bitwise_self_test.l
//
// `lyric test` synthesises a runnable program from the `test` blocks
// and compiles it IN-PROCESS through the self-hosted `Msil.Bridge`
// (lexer -> parser -> type-checker -> mode-checker -> codegen -> MSIL
// PE), then executes it and asserts every embedded assertion held.
// No `LYRIC_LOAD_COMPILER=1` is needed because this module imports
// only `Std.*` (no compiler packages).  No new F#: discovery is the
// native Lyric path, mirroring `weaver_self_test.l` / `cfg_gate_self_test.l`.
//
// Coverage is restricted to signed `Int` and `Long`.  Both the MSIL
// (`lyric-compiler/msil/codegen.l`) and JVM (`lyric-compiler/jvm/codegen.l`)
// backends lower these to signed opcodes only — `shr` is arithmetic
// (sign-replicating), and neither backend has an unsigned integer
// type, so the logical-shift paths are unreachable and intentionally
// untested here.  Keeping to signed Int/Long makes every assertion
// below valid on both `--target dotnet` and `--target jvm`.

@test_module
package Lyric.BitwiseSelfTest

import Std.Core
import Std.Testing

// ─────────────────────────────────────────────────────────────────────────────
// Int — bitwise logical ops
// ─────────────────────────────────────────────────────────────────────────────

test "Int.and masks bits" {
  // 0b0101 & 0b0011 = 0b0001
  assertEqualInt(5.and(3), 1, "5 & 3")
  // 0xFF & 0x0F = 0x0F
  assertEqualInt(255.and(15), 15, "255 & 15")
  // x & 0 == 0
  assertEqualInt(12345.and(0), 0, "x & 0")
}

test "Int.or sets bits" {
  // 0b0101 | 0b0011 = 0b0111
  assertEqualInt(5.or(3), 7, "5 | 3")
  // disjoint bits combine
  assertEqualInt(8.or(4), 12, "8 | 4")
  // x | 0 == x
  assertEqualInt(12345.or(0), 12345, "x | 0")
}

test "Int.xor toggles bits" {
  // 0b0101 ^ 0b0011 = 0b0110  (the issue's motivating case: 5.xor(3)==6)
  assertEqualInt(5.xor(3), 6, "5 ^ 3")
  // 0b1100 ^ 0b1010 = 0b0110
  assertEqualInt(12.xor(10), 6, "12 ^ 10")
  // x ^ x == 0
  assertEqualInt(12345.xor(12345), 0, "x ^ x")
  // x ^ 0 == x
  assertEqualInt(12345.xor(0), 12345, "x ^ 0")
}

test "Int bitwise ops compose" {
  // (5 ^ 3) & 6 == 6 & 6 == 6
  assertEqualInt(5.xor(3).and(6), 6, "(5 ^ 3) & 6")
  // (8 | 4) ^ 12 == 12 ^ 12 == 0
  assertEqualInt(8.or(4).xor(12), 0, "(8 | 4) ^ 12")
}

test "Int bitwise ops on negative operands" {
  // Bind `-1` to a local so the method call binds to the negated value
  // rather than parsing as `-(1.and(...))`.  Negative operands exercise
  // the two's-complement / sign-bit paths that the all-positive cases
  // above do not.
  val negOne: Int = -1
  // (-1) & 255 = 255 — masking strips the upper sign bits.
  assertEqualInt(negOne.and(255), 255, "-1 & 255")
  // (-1) | 0 = -1 — all-ones input dominates.
  assertEqualInt(negOne.or(0), -1, "-1 | 0")
  // (-1) ^ (-1) = 0 — same value cancels.
  assertEqualInt(negOne.xor(negOne), 0, "-1 ^ -1")
}

// ─────────────────────────────────────────────────────────────────────────────
// Int — shifts (shl logical, shr arithmetic / sign-replicating)
// ─────────────────────────────────────────────────────────────────────────────

test "Int.shl shifts left" {
  assertEqualInt(1.shl(4), 16, "1 << 4")
  assertEqualInt(3.shl(2), 12, "3 << 2")
  assertEqualInt(1.shl(0), 1, "1 << 0 (no-op)")
}

test "Int.shr is an arithmetic (sign-replicating) shift" {
  // positive operand: behaves like a logical shift
  assertEqualInt(16.shr(2), 4, "16 >> 2")
  // negative operand: sign bit is replicated (the issue's -8.shr(1)==-4)
  val neg8 = -8
  assertEqualInt(neg8.shr(1), -4, "-8 >> 1 (arithmetic)")
  // -1 stays -1 under any arithmetic right shift
  val negOne = -1
  assertEqualInt(negOne.shr(3), -1, "-1 >> 3 (arithmetic)")
}

// ─────────────────────────────────────────────────────────────────────────────
// Long — same surface, 64-bit width (exercises the LLand/LLor/LLxor/LLshl/LLshr
// JVM opcodes and the I8 MSIL path, distinct from the 32-bit Int opcodes above)
// ─────────────────────────────────────────────────────────────────────────────

// `Long` values are written with the `i64` integer-literal suffix: the
// self-hosted type-checker types an unsuffixed integer literal as `Int`
// and does not widen it to `Long` at a binding site (T0060), so `5i64`
// is the literal form that yields `PtLong`.

test "Long.and / .or / .xor" {
  val a: Long = 5i64
  val b: Long = 3i64
  assertEqualLong(a.and(b), 1i64, "5L & 3L == 1L")
  assertEqualLong(a.or(b), 7i64, "5L | 3L == 7L")
  assertEqualLong(a.xor(b), 6i64, "5L ^ 3L == 6L")
}

test "Long.shl reaches beyond 32 bits" {
  val one: Long = 1i64
  // 1L << 0 is a no-op, mirroring the Int.shl(0) zero-shift case.
  assertEqualLong(one.shl(0), 1i64, "1L << 0 (no-op)")
  // 1L << 40 = 1_099_511_627_776 — overflows Int32, proving 64-bit width.
  assertEqualLong(one.shl(40), 1099511627776i64, "1L << 40")
}

test "Long.shr is arithmetic (sign-replicating)" {
  val neg8: Long = -8i64
  assertEqualLong(neg8.shr(1), -4i64, "-8L >> 1 (arithmetic)")
}
