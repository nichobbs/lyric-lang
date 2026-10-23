//! string_split_intrinsic_self_test.l — dual-target runtime regression test for
//! the method form `s.split(sep)` (#7191).
//!
//! On dotnet the call is bound directly to `String.Split(string,
//! StringSplitOptions.None)`, so it no longer depends on `Std.String` being
//! linked into the bundle (it used to cascade to `Std.String.split` and throw
//! at run time when that module was absent).  Pins the edge cases the pure
//! Lyric `Std.String.split` defines: an empty separator yields the whole
//! string, adjacent and trailing separators yield empty elements, and an
//! absent separator yields one element.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/string_split_intrinsic_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/string_split_intrinsic_self_test.l
@test_module
package Lyric.StringSplitIntrinsicSelfTest

import Std.Core
import Std.Testing

test "split on a single-character separator" {
  val parts = "a,b,c".split(",")
  assertEqualInt(parts.length, 3, "three parts")
  assertEqual(parts[0], "a", "first")
  assertEqual(parts[2], "c", "last")
}

test "split on a multi-character separator" {
  val parts = "a--b--c".split("--")
  assertEqualInt(parts.length, 3, "three parts")
  assertEqual(parts[1], "b", "middle")
}

test "adjacent and trailing separators produce empty elements" {
  val parts = "a,,b,".split(",")
  assertEqualInt(parts.length, 4, "four parts")
  assertEqual(parts[1], "", "empty middle")
  assertEqual(parts[3], "", "empty tail")
}

test "an absent separator yields the whole string" {
  val parts = "abc".split(",")
  assertEqualInt(parts.length, 1, "one part")
  assertEqual(parts[0], "abc", "whole string")
}

test "an empty separator yields the whole string" {
  val parts = "abc".split("")
  assertEqualInt(parts.length, 1, "one part")
  assertEqual(parts[0], "abc", "whole string")
}

test "splitting the empty string yields one empty element" {
  val parts = "".split(",")
  assertEqualInt(parts.length, 1, "one part")
  assertEqual(parts[0], "", "empty")
}
