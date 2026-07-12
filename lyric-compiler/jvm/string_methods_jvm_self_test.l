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
//!   • 1-arg: indexOf/lastIndexOf(String) — routed to the UFCS
//!             `Std.String.indexOf/lastIndexOf(s, needle): Option[Int]`
//!             registered sig (the type the checker assigns; the original
//!             #1585 raw-JDK-int intrinsic silently diverged from MSIL and
//!             is now only the fallback for a bundle without `Std.String`)
//!   • 2-arg: replace(old, new) → replace(CharSequence, CharSequence) (String)
//!
//! Run via the native test runner on the JVM target:
//!
//!   lyric test --target jvm lyric-compiler/jvm/string_methods_jvm_self_test.l
//!
//! Known cross-target divergence (NOT covered here — this file is CI-wired
//! jvm-only): the MSIL backend still lowers `s.indexOf(x)` to the raw BCL
//! `String.IndexOf` int against the checker's `Option[Int]`, and its lenient
//! union match lets `case Some(_)` match the boxed int — so the two
//! None-expecting cases below fail on `--target dotnet` until the MSIL side
//! adopts the same UFCS routing the JVM backend now has.
@test_module
package Lyric.StringMethodsJvmSelfTest

import Std.Core
// Std.String must be in the import closure for `.indexOf`/`.lastIndexOf`:
// they are UFCS sugar for `Std.String.indexOf(s, needle): Option[Int]`, and
// the JVM bundles by import closure — exactly the requirement the checker
// imposes to type these calls in the first place.
import Std.String
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

test "indexOf returns the first occurrence as Some" {
  val s = "abcabc"
  match s.indexOf("bc") {
    case Some(i) -> assertEqualInt(i, 1, "indexOf first")
    case None -> assertTrue(false, "indexOf must find 'bc'")
  }
}

test "indexOf returns None when not found" {
  val s = "hello"
  match s.indexOf("xyz") {
    case Some(_) -> assertTrue(false, "indexOf must not find 'xyz'")
    case None -> assertTrue(true, "indexOf not-found is None")
  }
}

test "lastIndexOf returns the last occurrence as Some" {
  val s = "abcabc"
  match s.lastIndexOf("bc") {
    case Some(i) -> assertEqualInt(i, 4, "lastIndexOf last")
    case None -> assertTrue(false, "lastIndexOf must find 'bc'")
  }
}

test "lastIndexOf returns None when not found" {
  val s = "hello"
  match s.lastIndexOf("xyz") {
    case Some(_) -> assertTrue(false, "lastIndexOf must not find 'xyz'")
    case None -> assertTrue(true, "lastIndexOf not-found is None")
  }
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
