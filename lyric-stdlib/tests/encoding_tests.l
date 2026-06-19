//! stdlib/tests/encoding_tests.l — Tests for Std.Encoding.
//!
//! Covers Base64 encode/decode round-trip, hex encode/decode round-trip,
//! UTF-8 encode/decode round-trip, and the error paths (invalid Base64,
//! invalid hex, invalid UTF-8 byte sequence).
package Std.Encoding.Tests

import Std.Core
import Std.Encoding
import Std.Testing

func testBase64RoundTrip(): Unit {
  val bytes: slice[Byte] = [72u8, 101u8, 108u8, 108u8, 111u8]
  // "Hello"
  val encoded = encodeBase64(bytes)
  assertEqual(encoded, "SGVsbG8=", "base64 encode Hello")

  val decoded = tryDecodeBase64(encoded)
  assertTrue(isSome(decoded), "base64 decode succeeds")
  val back = unwrapOr(decoded, [])
  assertEqualInt(back.length, 5, "base64 round-trip length")
  assertEqualInt(back[0].toInt(), 72, "byte[0] H")
  assertEqualInt(back[4].toInt(), 111, "byte[4] o")
}

func testBase64Empty(): Unit {
  val encoded = encodeBase64([])
  assertEqual(encoded, "", "base64 empty encodes to empty")
  val decoded = tryDecodeBase64("")
  assertTrue(isSome(decoded), "base64 empty decodes ok")
  assertEqualInt(unwrapOr(decoded, []).length, 0, "base64 empty round-trip length")
}

func testBase64Invalid(): Unit {
  val bad = tryDecodeBase64("not!valid@base64#")
  assertTrue(isNone(bad), "invalid base64 returns None")
}

func testHexRoundTrip(): Unit {
  val bytes: slice[Byte] = [0u8, 255u8, 16u8, 31u8]
  val encoded = encodeHex(bytes)
  assertEqual(encoded, "00FF101F", "hex encode uppercase")

  val decoded = tryDecodeHex(encoded)
  assertTrue(isSome(decoded), "hex decode succeeds")
  val back = unwrapOr(decoded, [])
  assertEqualInt(back.length, 4, "hex round-trip length")
  assertEqualInt(back[0].toInt(), 0, "hex byte[0]")
  assertEqualInt(back[1].toInt(), 255, "hex byte[1]")
  assertEqualInt(back[2].toInt(), 16, "hex byte[2]")
}

func testHexLowerCase(): Unit {
  val decoded = tryDecodeHex("deadbeef")
  assertTrue(isSome(decoded), "lower-case hex decodes ok")
}

func testHexInvalid(): Unit {
  assertTrue(isNone(tryDecodeHex("xyz")), "non-hex chars return None")
  assertTrue(isNone(tryDecodeHex("abc")), "odd-length hex returns None")
}

func testUtf8RoundTrip(): Unit {
  val s = "Hello, World!"
  val bytes = encodeUtf8(s)
  assertTrue(bytes.length > 0, "utf8 encode non-empty")

  val decoded = tryDecodeUtf8(bytes)
  assertTrue(isSome(decoded), "utf8 decode succeeds")
  assertEqual(unwrapOr(decoded, ""), s, "utf8 round-trip matches")
}

func testUtf8Empty(): Unit {
  val bytes = encodeUtf8("")
  assertEqualInt(bytes.length, 0, "utf8 empty string encodes to empty")
  val decoded = tryDecodeUtf8([])
  assertTrue(isSome(decoded), "utf8 decode empty slice")
  assertEqual(unwrapOr(decoded, "x"), "", "utf8 decode empty matches")
}

func testUtf8Invalid(): Unit {
  // 0xFF is not valid UTF-8.
  val bad = tryDecodeUtf8([255u8])
  assertTrue(isNone(bad), "invalid utf8 byte returns None")
}

// ─── Numeric conversion opcodes (#2337) ──────────────────────────────────────
// The stage-0 emitter added Conv_I4 / Conv_I8 / Conv_R8 / Conv_U1 / Conv_U2
// to handle .toInt() / .toLong() / .toDouble() / .toByte() / .toChar() on
// numeric types.  These round-trip assertions cover each opcode path so that
// a wrong sign-extension or wrong stack-type annotation in the bootstrap
// emitter is caught before the F# bootstrap path is retired.
func testToIntConversion(): Unit {
  val b: Byte = 200u8
  assertEqualInt(b.toInt(), 200, "Byte.toInt — Conv_I4 zero-extends to Int")
}

func testToLongConversion(): Unit {
  val b: Byte = 42u8
  val n: Int = 100000
  // Byte → Long: Conv_I8 zero-extends.
  assertTrue(b.toLong() == 42i64, "Byte.toLong — Conv_I8 zero-extends Byte to Long")
  // Int → Long: Conv_I8 sign-extends.
  assertTrue(n.toLong() == 100000i64, "Int.toLong — Conv_I8 sign-extends Int to Long")
  // Negative Int must sign-extend (stay negative); positive inputs alone cannot
  // distinguish sign- from zero-extension, so cover a negative value.
  val neg: Int = 0 - 5
  assertTrue(neg.toLong() == 0i64 - 5i64, "Int.toLong — negative value sign-extends to a negative Long")
  // A Byte with the high bit set must zero-extend (stay 200), not sign-extend to -56.
  val hb: Byte = 200u8
  assertTrue(hb.toLong() == 200i64, "Byte.toLong — high-bit Byte zero-extends (200, not -56)")
}

func testToDoubleConversion(): Unit {
  val n: Int = 7
  val d: Double = n.toDouble()
  // Exact representation for small integers.
  assertTrue(d > 6.9 and d < 7.1, "Int.toDouble — Conv_R8 converts Int to Double")
}

func testToByteConversion(): Unit {
  val n: Int = 300
  // Conv_U1 truncates modulo 256: 300 % 256 = 44.
  val b: Byte = n.toByte()
  assertEqualInt(b.toInt(), 44, "Int.toByte — Conv_U1 truncates modulo 256")
}

func testToCharConversion(): Unit {
  val n: Int = 65
  // Conv_U2: Int 65 → Char 'A' (U+0041).
  val c: Char = n.toChar()
  assertTrue(c == 'A', "Int.toChar — Conv_U2 converts Int to Char")
}

func main(): Unit {
  testBase64RoundTrip()
  testBase64Empty()
  testBase64Invalid()
  testHexRoundTrip()
  testHexLowerCase()
  testHexInvalid()
  testUtf8RoundTrip()
  testUtf8Empty()
  testUtf8Invalid()
  testToIntConversion()
  testToLongConversion()
  testToDoubleConversion()
  testToByteConversion()
  testToCharConversion()
  println("encoding: ok")
}
