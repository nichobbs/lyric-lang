//! conv_methods_self_test.l — executable regression test for the numeric /
//! character conversion-method intrinsics `.toByte()` / `.toInt()` / `.toLong()`
//! / `.toChar()` / `.toDouble()` (#1901, Band-1 of epic #1470).
//!
//! Why this lives here and not in `lyric-stdlib/tests/*_tests.l`: like the
//! bitwise methods, these conversion methods are a *self-hosted-only* language
//! feature.  The F# stage-0 emitter that backs the `_tests.l` files does not
//! model them, so the test program itself must be compiled by the self-hosted
//! pipeline.  It is run by the native `lyric test` (issue #1611):
//!
//!   lyric test lyric-compiler/lyric/conv_methods_self_test.l            (MSIL)
//!   lyric test --target jvm lyric-compiler/lyric/conv_methods_self_test.l
//!
//! `lyric test` synthesises a runnable program from the `test` blocks and
//! compiles it IN-PROCESS through the self-hosted bridge (lexer -> parser ->
//! type-checker -> mode-checker -> codegen), then executes it and asserts every
//! embedded assertion held.  No `LYRIC_LOAD_COMPILER=1` is needed because this
//! module imports only `Std.*`.  Both backends lower the conversions to native
//! width-conversion opcodes — `conv.i4`/`conv.i8`/`conv.r8`/`conv.u1`/`conv.u2`
//! on MSIL; `i2l`/`l2i`/`d2i`/`l2d`/… on the JVM, with `.toByte()` using `& 0xFF`
//! masking rather than the *signed* `i2b` so the unsigned-`Byte` result matches
//! MSIL's `conv.u1` — so every assertion below is valid on both targets.
//!
//! The receiver is always bound to a `val` first: a bare-literal receiver such
//! as `42.toLong()` would lex the `42.` as the start of a float.
@test_module
package Lyric.ConvMethodsSelfTest

import Std.Core
import Std.Testing

// ─────────────────────────────────────────────────────────────────────────────
// Widening: Int -> Long / Double
// ─────────────────────────────────────────────────────────────────────────────
test "Int.toLong widens to 64-bit" {
  val x: Int = 42
  assertTrue(x.toLong() == 42i64, "42.toLong() == 42L")
  val neg: Int = -7
  assertTrue(neg.toLong() == -7i64, "(-7).toLong() == -7L (sign-extended)")
  // Shifting left 40 bits would overflow a 32-bit value: surviving it and
  // shifting back proves `.toLong()` really produced 64-bit width.
  assertEqualInt(x.toLong().shl(40).shr(40).toInt(), 42, "42.toLong() survives a 40-bit round-trip shift")
}

test "Int.toDouble widens to floating point" {
  val n: Int = 7
  assertTrue(n.toDouble() == 7.0, "7.toDouble() == 7.0")
}

// ─────────────────────────────────────────────────────────────────────────────
// Narrowing: Long -> Int, Double -> Int / Long (truncating toward zero)
// ─────────────────────────────────────────────────────────────────────────────
test "Long.toInt narrows to 32-bit" {
  val y: Long = 42i64
  assertEqualInt(y.toInt(), 42, "42L.toInt() == 42")
}

test "Double.toInt truncates toward zero" {
  val d: Double = 3.9
  assertEqualInt(d.toInt(), 3, "3.9.toInt() == 3")
  val dn: Double = -3.9
  assertEqualInt(dn.toInt(), -3, "(-3.9).toInt() == -3")
}

test "Double.toLong truncates toward zero" {
  val d: Double = 5.0
  assertTrue(d.toLong() == 5i64, "5.0.toLong() == 5L")
  val dt: Double = 9.9
  assertEqualInt(dt.toLong().toInt(), 9, "9.9.toLong().toInt() == 9 (truncated)")
}

// ─────────────────────────────────────────────────────────────────────────────
// Byte / Char round-trips — asserted via `.toInt()` so the result is comparable
// ─────────────────────────────────────────────────────────────────────────────
test "Int.toByte wraps to 0..255 then round-trips through toInt" {
  // 300 & 0xFF == 44
  val big: Int = 300
  assertEqualInt(big.toByte().toInt(), 44, "300.toByte().toInt() == 44")
  // an in-range value is preserved
  val ok: Int = 200
  assertEqualInt(ok.toByte().toInt(), 200, "200.toByte().toInt() == 200")
}

test "Long.toByte narrows through the low 8 bits" {
  // 513 & 0xFF == 1
  val L: Long = 513i64
  assertEqualInt(L.toByte().toInt(), 1, "513L.toByte().toInt() == 1")
}

test "Int.toChar round-trips through toInt" {
  val code: Int = 65
  assertEqualInt(code.toChar().toInt(), 65, "65.toChar().toInt() == 65 ('A')")
}

// ─────────────────────────────────────────────────────────────────────────────
// Byte as conversion source — exercises isNumericOrCharType(MByte)
// MSIL: conv.i4/conv.i8/conv.r8/conv.u2 (unsigned zero-extend from U1)
// JVM:  no-op for toInt (int-on-stack); l2d/i2l etc for wider targets
// ─────────────────────────────────────────────────────────────────────────────
test "Byte.toInt zero-extends to 32-bit" {
  // 200 is above 127 — confirm it stays positive (unsigned zero-extension)
  val b: Byte = 200.toByte()
  assertEqualInt(b.toInt(), 200, "Byte(200).toInt() == 200")
}

test "Byte.toLong zero-extends to 64-bit" {
  val b: Byte = 255.toByte()
  assertTrue(b.toLong() == 255i64, "Byte(255).toLong() == 255L")
}

test "Byte.toDouble widens to floating point" {
  val b: Byte = 10.toByte()
  assertTrue(b.toDouble() == 10.0, "Byte(10).toDouble() == 10.0")
}

test "Byte.toChar round-trips through toInt" {
  val b: Byte = 65.toByte()
  assertEqualInt(b.toChar().toInt(), 65, "Byte(65).toChar().toInt() == 65 ('A')")
}

// ─────────────────────────────────────────────────────────────────────────────
// Char as conversion source — exercises isNumericOrCharType(MChar)
// MSIL: conv.i4 (no-op U2->I4)/conv.i8/conv.u1/conv.r8
// JVM:  int-on-stack; l2i/i2l/d2i/l2d as for Int
// ─────────────────────────────────────────────────────────────────────────────
test "Char.toInt yields the code point" {
  val c: Char = 65.toChar()
  assertEqualInt(c.toInt(), 65, "Char(65).toInt() == 65 ('A')")
}

test "Char.toLong widens to 64-bit" {
  val c: Char = 66.toChar()
  assertTrue(c.toLong() == 66i64, "Char(66).toLong() == 66L")
}

test "Char.toByte narrows through the low 8 bits" {
  // code point 300 (U+012C 'Ĭ') & 0xFF == 44
  val c: Char = 300.toChar()
  assertEqualInt(c.toByte().toInt(), 44, "Char(300).toByte().toInt() == 44")
}

test "Char.toDouble widens to floating point" {
  val c: Char = 7.toChar()
  assertTrue(c.toDouble() == 7.0, "Char(7).toDouble() == 7.0")
}

// ─────────────────────────────────────────────────────────────────────────────
// Chaining — conversions compose left to right
// ─────────────────────────────────────────────────────────────────────────────
test "conversions chain" {
  val x: Int = 1000
  // 1000 -> Long -> Int round-trips losslessly
  assertEqualInt(x.toLong().toInt(), 1000, "1000.toLong().toInt() == 1000")
  // 1000 -> Byte (1000 & 0xFF == 232) -> Int
  assertEqualInt(x.toByte().toInt(), 232, "1000.toByte().toInt() == 232")
}
