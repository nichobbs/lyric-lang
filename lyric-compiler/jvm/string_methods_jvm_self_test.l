//! string_methods_jvm_self_test.l — JVM regression test for String instance
//! method dispatch (#1585): `trim`, `toUpper`, `toLower`, `indexOf`,
//! `lastIndexOf`, `length`, `replace`, and the existing `startsWith`,
//! `endsWith`, `contains`.
//!
//! Before this fix, String instance methods with non-Object return types fell
//! through to the generic `invokevirtual ... ret=Object` fallback in
//! `lowerMethodCall`.  This causes JVM VerifyErrors when the result is used as a
//! typed operand (e.g. `indexOf` returned as `int` then compared to `< 0`).
//!
//! The fix adds precise dispatches in `lowerMethodCall`:
//!   • 0-arg: trim/trimStart/trimEnd → strip/stripLeading/stripTrailing (String)
//!             toUpper → toUpperCase (String)
//!             toLower → toLowerCase (String)
//!             length  → length()    (int)
//!   • 1-arg: indexOf/lastIndexOf(String) → indexOf/lastIndexOf(String) (int)
//!   • 2-arg: replace(old, new) → replace(CharSequence, CharSequence) (String)
//!
//! Run via the native test runner on the JVM target:
//!
//!   lyric test --target jvm lyric-compiler/jvm/string_methods_jvm_self_test.l
@test_module
package Lyric.StringMethodsJvmSelfTest

import Std.Core
import Std.Testing

test "trim removes leading and trailing whitespace" {
  val s = "  hello  "
  assertEqual(s.trim(), "hello", "trim")
}

test "trimStart removes only leading whitespace" {
  val s = "  hello  "
  assertEqual(s.trimStart(), "hello  ", "trimStart")
}

test "trimEnd removes only trailing whitespace" {
  val s = "  hello  "
  assertEqual(s.trimEnd(), "  hello", "trimEnd")
}

test "toUpper converts to uppercase" {
  val s = "hello"
  assertEqual(s.toUpper(), "HELLO", "toUpper")
}

test "toLower converts to lowercase" {
  val s = "HELLO"
  assertEqual(s.toLower(), "hello", "toLower")
}

test "length returns character count" {
  val s = "hello"
  assertEqualInt(s.length, 5, "length")
}

test "indexOf returns position of first occurrence" {
  val s = "abcabc"
  assertEqualInt(s.indexOf("bc"), 1, "indexOf first")
}

test "indexOf returns -1 when not found" {
  val s = "hello"
  assertEqualInt(s.indexOf("xyz"), -1, "indexOf not found")
}

test "lastIndexOf returns position of last occurrence" {
  val s = "abcabc"
  assertEqualInt(s.lastIndexOf("bc"), 4, "lastIndexOf last")
}

test "lastIndexOf returns -1 when not found" {
  val s = "hello"
  assertEqualInt(s.lastIndexOf("xyz"), -1, "lastIndexOf not found")
}

test "replace substitutes all occurrences" {
  val s = "aabbcc"
  assertEqual(s.replace("bb", "XX"), "aaXXcc", "replace")
}

test "contains checks substring presence" {
  val s = "hello world"
  assertTrue(s.contains("world"), "contains true")
  assertTrue(not s.contains("xyz"), "contains false")
}

test "startsWith checks prefix" {
  val s = "hello world"
  assertTrue(s.startsWith("hello"), "startsWith true")
  assertTrue(not s.startsWith("world"), "startsWith false")
}

test "endsWith checks suffix" {
  val s = "hello world"
  assertTrue(s.endsWith("world"), "endsWith true")
  assertTrue(not s.endsWith("hello"), "endsWith false")
}

test "two-arg substring takes a count, not a Java end index (m-24)" {
  val s = "hello world"
  assertEqual(s.substring(6, 5), "world", "substring(6, 5) yields the 5 chars from index 6")
  assertEqual(s.substring(4, 1), "o", "substring(start > count) must not throw or reinterpret")
  assertEqual(s.substring(0, 5), "hello", "substring(0, 5) prefix")
  assertEqual(s.substring(10, 1), "d", "single trailing char")
}

test "one-arg substring takes the rest of the string" {
  val s = "hello world"
  assertEqual(s.substring(6), "world", "substring(6) rest-of-string")
}
