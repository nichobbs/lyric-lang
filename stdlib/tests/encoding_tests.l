// stdlib/tests/encoding_tests.l — Tests for Std.Encoding.
//
// Covers Base64 encode/decode round-trip, hex encode/decode round-trip,
// UTF-8 encode/decode round-trip, and the error paths (invalid Base64,
// invalid hex, invalid UTF-8 byte sequence).
package Std.Encoding.Tests

import Std.Core
import Std.Encoding
import Std.Testing

func testBase64RoundTrip(): Unit {
  val bytes: slice[Byte] = [72u8, 101u8, 108u8, 108u8, 111u8]  // "Hello"
  val encoded = encodeBase64(bytes)
  assertEqual(encoded, "SGVsbG8=", "base64 encode Hello")

  val decoded = tryDecodeBase64(encoded)
  assertTrue(isSome(decoded), "base64 decode succeeds")
  val back = unwrapOr(decoded, [])
  assertEqualInt(back.length, 5, "base64 round-trip length")
  assertEqualInt(back[0], 72, "byte[0] H")
  assertEqualInt(back[4], 111, "byte[4] o")
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
  assertEqualInt(back[0], 0, "hex byte[0]")
  assertEqualInt(back[1], 255, "hex byte[1]")
  assertEqualInt(back[2], 16, "hex byte[2]")
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
  println("encoding: ok")
}
