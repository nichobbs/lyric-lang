//! string_builder_self_test.l — runtime tests for the linear-time string
//! primitives in `Std.String`: `StringBuilder`, the builder-backed
//! `join`/`joinList`, and ordinal `indexOfFrom`/`indexOfFromRaw`
//! (#7257, #7258).
//!
//! Each primitive is backed by a different kernel per target
//! (`System.Text.StringBuilder` / `java.lang.StringBuilder` / a part list
//! concatenated by `lyric_string_concat_list`), so the same cases run on
//! every target:
//!   lyric test --target dotnet lyric-compiler/lyric/string_builder_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/string_builder_self_test.l
//!   lyric test --target native lyric-compiler/lyric/string_builder_self_test.l
//! Imports only `Std.*`, and avoids `assertPanics` (try/catch has no native
//! lowering, D-N-003) so the same file runs on all three.
@test_module
package Lyric.StringBuilderSelfTest

import Std.Core
import Std.Collections
import Std.String
import Std.Testing

test "empty builder yields the empty string" {
  val sb = StringBuilder.new()
  assertEqual(sb.toString(), "", "empty")
}

test "append and appendChar accumulate in order" {
  val sb = StringBuilder.new()
  sb.append("ab")
  sb.appendChar('c')
  sb.append("")
  sb.append("de")
  assertEqual(sb.toString(), "abcde", "accumulated")
}

test "toString leaves the builder usable and earlier results unchanged" {
  val sb = StringBuilder.new()
  sb.append("x")
  val first = sb.toString()
  sb.append("y")
  assertEqual(first, "x", "earlier result")
  assertEqual(sb.toString(), "xy", "after further append")
}

test "builder handles many appends" {
  val sb = StringBuilder.new()
  var i = 0
  while i < 20000 {
    sb.appendChar('a')
    i += 1
  }
  val s = sb.toString()
  assertEqualInt(s.length, 20000, "length")
  assertTrue(s.startsWith("aaaa"), "content")
}

test "join places the separator only between parts" {
  val empty: List[String] = newList()
  assertEqual(join(",", empty.toArray()), "", "no parts")
  assertEqual(join(",", ["a"]), "a", "one part")
  assertEqual(join(", ", ["a", "b", "c"]), "a, b, c", "three parts")
  assertEqual(join("", ["a", "b"]), "ab", "empty separator")
  assertEqual(join(",", ["", "", ""]), ",,", "empty parts")
}

test "joinList matches join" {
  val xs: List[String] = newList()
  assertEqual(joinList("-", xs), "", "empty list")
  xs.add("x")
  assertEqual(joinList("-", xs), "x", "one element")
  xs.add("y")
  xs.add("z")
  assertEqual(joinList("-", xs), "x-y-z", "three elements")
}

test "indexOfFromRaw finds matches at or after from" {
  val s = "a,b,,c"
  assertEqualInt(indexOfFromRaw(s, ",", 0), 1, "from 0")
  assertEqualInt(indexOfFromRaw(s, ",", 1), 1, "match at from")
  assertEqualInt(indexOfFromRaw(s, ",", 2), 3, "skips earlier match")
  assertEqualInt(indexOfFromRaw(s, ",", 4), 4, "adjacent separator")
  assertEqualInt(indexOfFromRaw(s, ",", 5), -1, "none after from")
  assertEqualInt(indexOfFromRaw(s, ",", 6), -1, "from at end")
  assertEqualInt(indexOfFromRaw(s, "b,", 3), -1, "multi-char needle before from")
  assertEqualInt(indexOfFromRaw("aaab", "ab", 1), 2, "partial-prefix candidate")
}

test "indexOfFromRaw with an empty needle matches at from" {
  assertEqualInt(indexOfFromRaw("abc", "", 0), 0, "start")
  assertEqualInt(indexOfFromRaw("abc", "", 2), 2, "middle")
  assertEqualInt(indexOfFromRaw("abc", "", 3), 3, "end")
}

test "indexOfFrom wraps the result in Option" {
  match indexOfFrom("hello world", "o", 5) {
    case Some(i) -> assertEqualInt(i, 7, "second o")
    case None -> assertTrue(false, "expected a match")
  }
  match indexOfFrom("hello", "z", 0) {
    case Some(_) -> assertTrue(false, "expected no match")
    case None -> assertTrue(true, "no match")
  }
}

test "a forward scan with indexOfFrom collects every occurrence" {
  val s = "x=1;y=2;z=3"
  val found: List[Int] = newList()
  var pos = 0
  var more = true
  while more {
    val i = indexOfFromRaw(s, ";", pos)
    if i < 0 {
      more = false
    } else {
      found.add(i)
      pos = i + 1
    }
  }
  assertEqualInt(found.count, 2, "two separators")
  assertEqualInt(found[0], 3, "first")
  assertEqualInt(found[1], 7, "second")
}
