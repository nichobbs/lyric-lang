//! string_code_points_self_test.l — the code-unit and code-point views of a
//! `String` (D-progress-1006), with expectations that hold on every target.
//!
//! A `Char` is a BMP scalar value (docs/01 §2.1), so a supplementary-plane
//! character such as U+1F600 is reachable only as a code point (`Int`) or as
//! text.  `Std.String.codePoints`/`codePointAt` decode UTF-16 on .NET and the
//! JVM and UTF-8 on native, so the scalar values below are the same on all
//! three; code-unit indices differ (UTF-16 units vs UTF-8 bytes), so this
//! file only indexes at positions that start a character on every target.
//! The failing cases (`s[i]` on a surrogate half, a checked `.toChar()`)
//! need try/catch and live in `string_bounds_self_test.l` and
//! `conv_methods_self_test.l`.
//!
//!   lyric test --target dotnet lyric-compiler/lyric/string_code_points_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/string_code_points_self_test.l
//!   lyric test --target native lyric-compiler/lyric/string_code_points_self_test.l
@test_module
package Lyric.StringCodePointsSelfTest

import Std.Core
import Std.Char
import Std.Encoding
import Std.String
import Std.Testing

// Matched rather than `isSome[Char](...)`: `--target native` does not yet
// lower an explicit type application on a generic call.
func hasChar(o: in Option[Char]): Bool {
  match o {
    case Some(_) -> true
    case None -> false
  }
}

test "codePoints decodes mixed text" {
  val cps = codePoints("aé😀€")
  assertEqualInt(cps.length, 4, "four scalar values")
  assertEqualInt(cps[0], 97, "a")
  assertEqualInt(cps[1], 233, "e acute")
  assertEqualInt(cps[2], 128512, "U+1F600")
  assertEqualInt(cps[3], 8364, "euro sign")
  assertEqualInt(codePoints("").length, 0, "empty string")
}

test "codePointAt at the start of each character" {
  val s = "😀a"
  assertEqualInt(codePointAt(s, 0), 128512, "supplementary-plane scalar")
  assertEqualInt(codePointAt("é", 0), 233, "two-byte / one-unit scalar")
}

test "a code point round-trips through codepointToString" {
  var rebuilt = ""
  for cp in codePoints("x😀y") {
    rebuilt = rebuilt + codepointToString(cp)
  }
  assertEqual(rebuilt, "x😀y", "decode then re-encode is the identity")
}

test "BMP characters index as Char" {
  val s = "éz"
  assertTrue(s[0] == '\u{00e9}', "s[0] is a BMP Char")
  assertTrue(hasChar(charAt(s, 0)), "charAt at a character start")
  assertTrue(charAtOrReplacement("😀", 0) == '\u{fffd}', "no Char for U+1F600")
  assertEqualInt("A".codeUnitAt(0), 65, "an ASCII code unit is its value")
}

test "the Char conversions accept exactly the BMP scalar values" {
  val a: Int = 65
  assertTrue(a.toChar() == 'A', "65.toChar() is 'A'")
  assertTrue(not hasChar(tryFromInt(55296)), "no Char for 0xD800")
  assertTrue(not hasChar(tryFromInt(128512)), "no Char for U+1F600")
  assertTrue(hasChar(tryFromInt(65535)), "0xFFFF is a Char")
}
