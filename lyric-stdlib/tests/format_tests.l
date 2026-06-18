//! stdlib/tests/format_tests.l — Tests for Std.Format.
//!
//! Covers: toHexString, toHexStringUpper, formatFixed, padLeft,
//! padRight, zeroPad, hexPad, hexPadUpper.
package Std.Format.Tests

import Std.Format
import Std.Testing

func testToHexString(): Unit {
  assertEqual(toHexString(0), "0", "hex 0")
  assertEqual(toHexString(255), "ff", "hex 255")
  assertEqual(toHexString(16), "10", "hex 16")
  assertEqual(toHexString(256), "100", "hex 256")
}

func testToHexStringUpper(): Unit {
  assertEqual(toHexStringUpper(0), "0", "hexUpper 0")
  assertEqual(toHexStringUpper(255), "FF", "hexUpper 255")
  assertEqual(toHexStringUpper(16), "10", "hexUpper 16")
}

func testFormatFixed(): Unit {
  assertEqual(formatFixed(3.14159, 2), "3.14", "fixed 2dp")
  assertEqual(formatFixed(1.0, 4), "1.0000", "fixed 4dp")
  assertEqual(formatFixed(0.0, 0), "0", "fixed 0dp")
  assertEqual(formatFixed(100.5, 1), "100.5", "fixed 1dp 100.5")
}

func testPadLeft(): Unit {
  assertEqual(padLeft("42", 5, '0'), "00042", "padLeft zeros")
  assertEqual(padLeft("hello", 3, ' '), "hello", "padLeft no-op when long enough")
  assertEqual(padLeft("", 3, '-'), "---", "padLeft empty string")
}

func testPadRight(): Unit {
  assertEqual(padRight("hi", 5, '.'), "hi...", "padRight dots")
  assertEqual(padRight("hello", 3, ' '), "hello", "padRight no-op when long enough")
  assertEqual(padRight("", 3, 'x'), "xxx", "padRight empty string")
}

func testZeroPad(): Unit {
  assertEqual(zeroPad(7, 3), "007", "zeroPad 7 width 3")
  assertEqual(zeroPad(42, 2), "42", "zeroPad exact width")
  assertEqual(zeroPad(100, 2), "100", "zeroPad overflow")
  assertEqual(zeroPad(0, 4), "0000", "zeroPad zero")
}

func testHexPad(): Unit {
  assertEqual(hexPad(255, 4), "00ff", "hexPad 255 width 4")
  assertEqual(hexPad(0, 2), "00", "hexPad 0 width 2")
  assertEqual(hexPad(256, 2), "100", "hexPad overflow")
}

func testHexPadUpper(): Unit {
  assertEqual(hexPadUpper(255, 4), "00FF", "hexPadUpper 255 width 4")
  assertEqual(hexPadUpper(0, 2), "00", "hexPadUpper 0 width 2")
}

func main(): Unit {
  testToHexString()
  testToHexStringUpper()
  testFormatFixed()
  testPadLeft()
  testPadRight()
  testZeroPad()
  testHexPad()
  testHexPadUpper()
  println("format: ok")
}
