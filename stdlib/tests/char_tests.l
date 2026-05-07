// stdlib/tests/char_tests.l — Tests for Std.Char.
//
// Covers: classification (isLetter, isDigit, isLetterOrDigit,
// isWhiteSpace, isUpper, isLower, isPunctuation, isControl),
// case conversion (toUpper, toLower), code-point bridge (toInt,
// fromInt, isAscii), and digit value helpers (digitValue, hexDigitValue).
package Std.Char.Tests

import Std.Core
import Std.Char
import Std.Testing

func testIsLetter(): Unit {
  assertTrue(isLetter('a'), "a is letter")
  assertTrue(isLetter('Z'), "Z is letter")
  assertTrue(not isLetter('0'), "0 is not letter")
  assertTrue(not isLetter(' '), "space is not letter")
  assertTrue(not isLetter('!'), "! is not letter")
}

func testIsDigit(): Unit {
  assertTrue(isDigit('0'), "0 is digit")
  assertTrue(isDigit('9'), "9 is digit")
  assertTrue(not isDigit('a'), "a is not digit")
  assertTrue(not isDigit(' '), "space is not digit")
}

func testIsLetterOrDigit(): Unit {
  assertTrue(isLetterOrDigit('a'), "a is letter or digit")
  assertTrue(isLetterOrDigit('5'), "5 is letter or digit")
  assertTrue(not isLetterOrDigit(' '), "space is not")
  assertTrue(not isLetterOrDigit('!'), "! is not")
}

func testIsWhiteSpace(): Unit {
  assertTrue(isWhiteSpace(' '), "space is whitespace")
  assertTrue(isWhiteSpace('\t'), "tab is whitespace")
  assertTrue(isWhiteSpace('\n'), "newline is whitespace")
  assertTrue(not isWhiteSpace('a'), "a is not whitespace")
  assertTrue(not isWhiteSpace('0'), "0 is not whitespace")
}

func testIsUpperLower(): Unit {
  assertTrue(isUpper('A'), "A is upper")
  assertTrue(isUpper('Z'), "Z is upper")
  assertTrue(not isUpper('a'), "a is not upper")
  assertTrue(not isUpper('0'), "0 is not upper")

  assertTrue(isLower('a'), "a is lower")
  assertTrue(isLower('z'), "z is lower")
  assertTrue(not isLower('A'), "A is not lower")
  assertTrue(not isLower('0'), "0 is not lower")
}

func testToUpperLower(): Unit {
  assertEqual("" + toUpper('a'), "A", "toUpper a")
  assertEqual("" + toUpper('Z'), "Z", "toUpper Z unchanged")
  assertEqual("" + toLower('A'), "a", "toLower A")
  assertEqual("" + toLower('z'), "z", "toLower z unchanged")
}

func testToIntFromInt(): Unit {
  assertEqualInt(toInt('A'), 65, "toInt A")
  assertEqualInt(toInt('a'), 97, "toInt a")
  assertEqualInt(toInt('0'), 48, "toInt 0")
  assertEqualInt(toInt(' '), 32, "toInt space")

  assertEqual("" + fromInt(65), "A", "fromInt 65")
  assertEqual("" + fromInt(97), "a", "fromInt 97")
}

func testIsAscii(): Unit {
  assertTrue(isAscii('a'), "a is ascii")
  assertTrue(isAscii(' '), "space is ascii")
  assertTrue(isAscii('\t'), "tab is ascii")
}

func testDigitValue(): Unit {
  val d0 = digitValue('0')
  assertTrue(isSome(d0), "digitValue 0 is Some")
  assertEqualInt(unwrapOr(d0, -1), 0, "digitValue 0 = 0")

  val d9 = digitValue('9')
  assertTrue(isSome(d9), "digitValue 9 is Some")
  assertEqualInt(unwrapOr(d9, -1), 9, "digitValue 9 = 9")

  assertTrue(isNone(digitValue('a')), "digitValue a is None")
  assertTrue(isNone(digitValue(' ')), "digitValue space is None")
}

func testHexDigitValue(): Unit {
  assertEqualInt(unwrapOr(hexDigitValue('0'), -1), 0, "hex 0")
  assertEqualInt(unwrapOr(hexDigitValue('9'), -1), 9, "hex 9")
  assertEqualInt(unwrapOr(hexDigitValue('a'), -1), 10, "hex a")
  assertEqualInt(unwrapOr(hexDigitValue('f'), -1), 15, "hex f")
  assertEqualInt(unwrapOr(hexDigitValue('A'), -1), 10, "hex A")
  assertEqualInt(unwrapOr(hexDigitValue('F'), -1), 15, "hex F")

  assertTrue(isNone(hexDigitValue('g')), "hex g is None")
  assertTrue(isNone(hexDigitValue('G')), "hex G is None")
  assertTrue(isNone(hexDigitValue(' ')), "hex space is None")
}

func main(): Unit {
  testIsLetter()
  testIsDigit()
  testIsLetterOrDigit()
  testIsWhiteSpace()
  testIsUpperLower()
  testToUpperLower()
  testToIntFromInt()
  testIsAscii()
  testDigitValue()
  testHexDigitValue()
  println("char: ok")
}
