//! string_bounds_self_test.l — failures of string indexing and search
//! bounds that must not pass silently.
//!
//! `Std.String.indexOfFrom`/`indexOfFromRaw` reject an out-of-range start
//! through their `requires:` clause (#7258): the hosts disagree here (.NET
//! `IndexOf` throws, JVM `indexOf` clamps), so the contract is what makes the
//! targets agree.
//!
//! `s[i]` rejects an index holding a UTF-16 surrogate half (D-progress-1006):
//! a `Char` is a BMP scalar value (docs/01 §2.1), so the failure is the same
//! class as an out-of-range index, never a surrogate `Char`.  The raw
//! `s.codeUnitAt(i)` and the decoding `Std.String.codePointAt` read every
//! position.  The UTF-16-specific expectations here (code-unit values and
//! indices of an emoji's halves) hold on .NET and the JVM; the target-neutral
//! code-point cases, which also run on `--target native`, live in
//! `string_code_points_self_test.l`.
//!
//! Uses `assertPanics`, which needs try/catch, so it runs on dotnet and the
//! JVM only (native has no unwinding, D-N-003; `lyric_string_index_of_from`
//! and `lyric_string_char_at` panic on the same inputs and are covered by the
//! lyric-rt C tests).
//!
//!   lyric test --target dotnet lyric-compiler/lyric/string_bounds_self_test.l
//!   lyric test --target jvm    lyric-compiler/lyric/string_bounds_self_test.l
@test_module
package Lyric.StringBoundsSelfTest

import Std.Core
import Std.String
import Std.Testing

test "indexOfFromRaw rejects a negative start" {
  assertPanics("negative from", { -> val _ = indexOfFromRaw("abc", "a", -1) })
}

test "indexOfFrom rejects a start past the end" {
  assertPanics("from past the end", { -> val _ = indexOfFrom("abc", "a", 4) })
}

test "a start equal to the length is accepted" {
  assertEqualInt(indexOfFromRaw("abc", "a", 3), -1, "no match at end")
  assertEqualInt(indexOfFromRaw("abc", "", 3), 3, "empty needle at end")
}

test "s[i] reads a BMP character" {
  val s = "aé😀z"
  assertTrue(s[0] == 'a', "ASCII")
  assertTrue(s[1] == '\u{00e9}', "BMP, non-ASCII")
  assertTrue(s[4] == 'z', "after the surrogate pair")
}

test "s[i] rejects a surrogate half" {
  val s = "aé😀z"
  assertPanicsWith("high surrogate", "surrogate", { -> val _ = s[2] })
  assertPanicsWith("low surrogate", "surrogate", { -> val _ = s[3] })
}

test "codeUnitAt returns the raw UTF-16 unit" {
  val s = "a😀"
  assertEqualInt(s.codeUnitAt(0), 97, "ASCII unit")
  assertEqualInt(s.codeUnitAt(1), 55357, "high surrogate 0xD83D")
  assertEqualInt(s.codeUnitAt(2), 56832, "low surrogate 0xDE00")
  assertEqualInt(codeUnitAt(s, 2), 56832, "free-function form")
  assertPanics("out of range", { -> val _ = s.codeUnitAt(3) })
}

test "codePointAt decodes pairs and replaces lone halves" {
  val s = "a😀"
  assertEqualInt(codePointAt(s, 1), 128512, "pair decodes to U+1F600")
  assertEqualInt(codePointAt(s, 2), 65533, "trailing half is U+FFFD")
  val lone = s.substring(0, 2)
  assertEqualInt(lone.length, 2, "lone high surrogate kept by substring")
  assertEqualInt(codePointAt(lone, 1), 65533, "unpaired high half is U+FFFD")
}

test "charAt, first and last give None at a surrogate half" {
  val s = "😀x😀"
  assertTrue(isNone[Char](charAt(s, 0)), "charAt on a high half")
  assertTrue(isSome[Char](charAt(s, 2)), "charAt on a BMP char")
  assertTrue(isNone[Char](first(s)), "first is a high half")
  assertTrue(isNone[Char](last(s)), "last is a low half")
  assertTrue(charAtOrReplacement(s, 1) == '\u{fffd}', "replacement for a low half")
  assertTrue(charAtOrReplacement(s, 2) == 'x', "a real Char passes through")
}
