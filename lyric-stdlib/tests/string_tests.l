//! stdlib/tests/string_tests.l — Tests for Std.String.
//!
//! Tests string inspection, search, case conversion, construction, and
//! character access functions. Each test function panics via Std.Testing
//! on any mismatch; exit code 0 means all assertions held.
package Std.String.Tests

import Std.Core
import Std.String
import Std.Testing

func testInspection(): Unit {
  assertEqualInt(length("hello"), 5, "length hello")
  assertEqualInt(length(""), 0, "length empty")

  assertTrue(isEmpty(""), "isEmpty empty")
  assertTrue(not isEmpty("x"), "isEmpty non-empty")
  assertTrue(isNotEmpty("x"), "isNotEmpty non-empty")
  assertTrue(not isNotEmpty(""), "isNotEmpty empty")

  assertEqual(trim("  hi  "), "hi", "trim")
  assertEqual(trimStart("  hi  "), "hi  ", "trimStart")
  assertEqual(trimEnd("  hi  "), "  hi", "trimEnd")
}

func testSearch(): Unit {
  assertTrue(startsWith("hello", "hel"), "startsWith match")
  assertTrue(not startsWith("hello", "xyz"), "startsWith no match")

  assertTrue(endsWith("hello", "lo"), "endsWith match")
  assertTrue(not endsWith("hello", "he"), "endsWith no match")

  assertTrue(contains("hello world", "world"), "contains match")
  assertTrue(not contains("hello", "xyz"), "contains no match")

  val idx = indexOf("hello", "ll")
  assertTrue(isSome(idx), "indexOf found")
  assertEqualInt(unwrapOr(idx, -1), 2, "indexOf value")
  assertTrue(isNone(indexOf("hello", "xyz")), "indexOf not found")

  val last = lastIndexOf("abab", "ab")
  assertTrue(isSome(last), "lastIndexOf found")
  assertEqualInt(unwrapOr(last, -1), 2, "lastIndexOf value")
}

func testSubstring(): Unit {
  assertEqual(substring("hello", 2, 3), "llo", "substring from index")
  assertEqual(substring("hello", 1, 3), "ell", "substring with count")
}

func testCase(): Unit {
  assertEqual(toUpper("hello"), "HELLO", "toUpper")
  assertEqual(toLower("HELLO"), "hello", "toLower")
  assertTrue(equalsCaseInsensitive("Hello", "hello"), "equalsCaseInsensitive match")
  assertTrue(not equalsCaseInsensitive("Hi", "hello"), "equalsCaseInsensitive no match")
}

func testConstruction(): Unit {
  assertEqual(repeat("ab", 3), "ababab", "repeat")
  assertEqual(repeat("x", 0), "", "repeat zero")
  assertEqual(replace("aabbcc", "bb", "XX"), "aaXXcc", "replace")

  val parts = split("a,b,c", ",")
  assertEqualInt(parts.length, 3, "split count")
  assertEqual(parts[0], "a", "split[0]")
  assertEqual(parts[1], "b", "split[1]")
  assertEqual(parts[2], "c", "split[2]")

  assertEqual(join("-", ["x", "y", "z"]), "x-y-z", "join")
  assertEqual(join(",", []), "", "join empty")
}

// Separator placement, multi-character and partially-matching separators,
// and the non-overlapping left-to-right match rule (.NET String.Split
// semantics).
func testSplitEdges(): Unit {
  assertEqual(join("|", split("", ",")), "", "split empty input")
  assertEqualInt(split("", ",").length, 1, "split empty input count")
  assertEqual(join("|", split("abc", "")), "abc", "split empty separator")
  assertEqual(join("|", split(",a,,b,", ",")), "|a||b|", "split leading/adjacent/trailing")
  assertEqualInt(split(",a,,b,", ",").length, 5, "split leading/adjacent/trailing count")
  assertEqual(join("|", split("a\nb\n", "\n")), "a|b|", "split lines with trailing newline")
  assertEqual(join("|", split("x::y:z::", "::")), "x|y:z|", "split multi-char separator")
  assertEqual(join("|", split("aXbXXc", "XX")), "aXb|c", "split partial separator prefix")
  assertEqual(join("|", split("aaaa", "aa")), "||", "split non-overlapping matches")
  assertEqual(join("|", split("aaa", "aa")), "|a", "split odd-length overlap")
  assertEqual(join("|", split("ab", "abc")), "ab", "split separator longer than input")
}

func testCompare(): Unit {
  assertEqualInt(compare("a", "b"), -1, "compare a < b")
  assertEqualInt(compare("b", "a"), 1, "compare b > a")
  assertEqualInt(compare("a", "a"), 0, "compare equal")
  assertTrue(equals("hi", "hi"), "equals same")
  assertTrue(not equals("hi", "HI"), "equals different case")
}

func testCharAccess(): Unit {
  val c0 = charAt("hello", 0)
  assertTrue(isSome(c0), "charAt 0 found")

  assertTrue(isSome(first("hello")), "first non-empty")
  assertTrue(isNone(first("")), "first empty")

  assertTrue(isSome(last("hello")), "last non-empty")
  assertTrue(isNone(last("")), "last empty")

  assertTrue(isNone(charAt("hi", 99)), "charAt out of bounds")
}

func main(): Unit {
  testInspection()
  testSearch()
  testSubstring()
  testCase()
  testConstruction()
  testSplitEdges()
  testCompare()
  testCharAccess()
  println("string: ok")
}
