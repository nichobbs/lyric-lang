//! split_self_test.l — pins `Std.String.split`'s semantics on every target:
//! ordinal, left-to-right, non-overlapping separator matching with .NET
//! `String.Split` placement rules (empty separator returns the input whole;
//! leading, adjacent and trailing separators yield empty parts).
//!
//! `split` was rewritten from a remainder-re-slicing loop (quadratic in the
//! input length, and bound to the culture-sensitive BCL `IndexOf` on MSIL)
//! into a single forward scan; these cases guard that rewrite. Imports only
//! `Std.*`, so it runs unchanged under each backend:
//!   lyric test lyric-compiler/lyric/split_self_test.l
//!   lyric test lyric-compiler/lyric/split_self_test.l --target jvm
//!   lyric test lyric-compiler/lyric/split_self_test.l --target native
@test_module
package Lyric.SplitSelfTest

import Std.Core
import Std.Testing
import Std.String as Str

test "empty input yields one empty part" {
  val parts = Str.split("", ",")
  assertEqualInt(parts.length, 1, "part count")
  assertEqual(parts[0], "", "the single part")
}

test "empty separator returns the input unchanged" {
  val parts = Str.split("abc", "")
  assertEqualInt(parts.length, 1, "part count")
  assertEqual(parts[0], "abc", "the single part")
}

test "leading, adjacent and trailing separators yield empty parts" {
  val parts = Str.split(",a,,b,", ",")
  assertEqualInt(parts.length, 5, "part count")
  assertEqual(Str.join("|", parts), "|a||b|", "parts")
}

test "splitting lines keeps the empty part after a trailing newline" {
  assertEqual(Str.join("|", Str.split("a\nb\n", "\n")), "a|b|", "parts")
}

test "multi-character separator" {
  assertEqual(Str.join("|", Str.split("x::y:z::", "::")), "x|y:z|", "parts")
}

test "a partial separator prefix is not a match" {
  assertEqual(Str.join("|", Str.split("aXbXXc", "XX")), "aXb|c", "parts")
}

test "matches are non-overlapping, left to right" {
  assertEqual(Str.join("|", Str.split("aaaa", "aa")), "||", "even run")
  assertEqual(Str.join("|", Str.split("aaa", "aa")), "|a", "odd run")
}

test "separator longer than the input" {
  val parts = Str.split("ab", "abc")
  assertEqualInt(parts.length, 1, "part count")
  assertEqual(parts[0], "ab", "the single part")
}

test "no separator present" {
  val parts = Str.split("hello", ",")
  assertEqualInt(parts.length, 1, "part count")
  assertEqual(parts[0], "hello", "the single part")
}
