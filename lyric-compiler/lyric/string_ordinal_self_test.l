//! string_ordinal_self_test.l — String search is ordinal on every target
//! (#7260).
//!
//! MSIL used to bind the single-argument `String.IndexOf(string)`,
//! `LastIndexOf(string)`, `StartsWith(string)` and `EndsWith(string)`
//! overloads, which compare with the current culture (ICU on Linux). Under
//! a linguistic comparison an ignorable code point such as U+00AD SOFT
//! HYPHEN matches as an empty string, so `"abc".IndexOf("\u00AD")` was 0
//! and `StartsWith` was true, and CR LF can be treated as one text element
//! depending on the ICU version. The JVM and native targets were already
//! ordinal, so results differed by target. This module deliberately does not
//! import `Std.String`, so the method spellings below exercise the raw
//! intrinsics each backend lowers them to.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/string_ordinal_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/string_ordinal_self_test.l
//!   lyric test --target native lyric-compiler/lyric/string_ordinal_self_test.l
@test_module
package Lyric.StringOrdinalSelfTest

import Std.Core
import Std.Testing

test "indexOf finds a lone LF inside a CR LF pair" {
  assertEqualInt("a\r\nb".indexOf("\n"), 2, "LF after CR")
  assertEqualInt("a\r\nb".indexOf("\r"), 1, "CR before LF")
}

test "lastIndexOf finds a lone LF inside a CR LF pair" {
  assertEqualInt("x\r\ny\r\nz".lastIndexOf("\n"), 5, "last LF")
}

test "an ignorable code point does not match as empty" {
  val shy = "­"
  assertEqualInt("abc".indexOf(shy), -1, "indexOf soft hyphen")
  assertEqualInt("abc".lastIndexOf(shy), -1, "lastIndexOf soft hyphen")
  assertFalse("abc".startsWith(shy), "startsWith soft hyphen")
  assertFalse("abc".endsWith(shy), "endsWith soft hyphen")
}

test "startsWith and endsWith compare code units exactly" {
  assertTrue("\r\nrest".startsWith("\r"), "prefix CR of CR LF")
  assertTrue("line\r\n".endsWith("\n"), "suffix LF of CR LF")
  assertFalse("abc".startsWith("ABC"), "case-sensitive prefix")
}
