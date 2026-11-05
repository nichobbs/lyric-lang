@test_module
package Unicode.WordBreakTests

import Std.Core
import Std.Collections
import Std.String
import Std.Encoding.{codepointToString}
import Std.Testing
import Unicode.WordBreak

// `s` with a bar at every word boundary inside it.
func marked(s: String): String {
  val cps = codePoints(s)
  val bounds = WordBreak.boundariesIn(cps, 0, cps.length)
  var r = ""
  var i = 0
  while i < cps.length {
    if i > 0 and bounds[i] {
      r = r + "|"
    }
    r = r + codepointToString(cps[i])
    i = i + 1
  }
  r
}

// The caret positions Ctrl+Right visits from the start of `s`, then those Ctrl+Left visits back.
func rightStops(s: String): String {
  val cps = codePoints(s)
  var r = ""
  var p = 0
  var steps = 0
  while p < cps.length and steps < 50 {
    p = WordBreak.nextWordEnd(cps, p)
    r = r + (if r.length > 0 { " " } else { "" }) + fromInt(p)
    steps = steps + 1
  }
  r
}

func leftStops(s: String): String {
  val cps = codePoints(s)
  var r = ""
  var p = cps.length
  var steps = 0
  while p > 0 and steps < 50 {
    p = WordBreak.previousWordStart(cps, p)
    r = r + (if r.length > 0 { " " } else { "" }) + fromInt(p)
    steps = steps + 1
  }
  r
}

test "words, spaces and punctuation are separate segments" {
  assertEqual(marked("The quick (\"brown\") fox"), "The| |quick| |(|\"|brown|\"|)| |fox", "UAX #29 figure 1")
  assertEqual(marked("a  b"), "a|  |b", "a run of spaces is one segment")
}

test "apostrophes, full stops and number separators stay inside words" {
  assertEqual(marked("can't"), "can't", "an apostrophe between letters")
  assertEqual(marked("e.g. example.com"), "e.g|.| |example.com", "full stops between letters")
  assertEqual(marked("3,456.789"), "3,456.789", "separators between digits")
  assertEqual(marked("A3 3a"), "A3| |3a", "letters next to digits")
  assertEqual(marked("snake_case"), "snake_case", "a connector")
}

test "marks and joiners stay with what they follow" {
  assertEqual(marked("éa b"), "éa| |b", "a combining mark inside a word")
  assertEqual(marked("👨\u{200d}👩"), "👨\u{200d}👩", "an emoji ZWJ sequence")
  assertEqual(marked("🇦🇧🇨"), "🇦🇧|🇨", "regional indicators pair up")
}

test "ideographs are one segment each, Katakana runs one" {
  assertEqual(marked("漢字"), "漢|字", "ideographs")
  assertEqual(marked("カタカナ"), "カタカナ", "Katakana")
}

test "Hebrew letters keep their geresh and gershayim" {
  assertEqual(marked("צה\"ל"), "צה\"ל", "a gershayim written as a quotation mark")
}

test "a segment is a word when it has a letter, digit, kana or ideograph" {
  val cps = codePoints("ab 12 ,; 漢 あ ไทย")
  assertTrue(WordBreak.isWordLike(cps, 0, 2), "letters")
  assertTrue(WordBreak.isWordLike(cps, 3, 5), "digits")
  assertFalse(WordBreak.isWordLike(cps, 2, 3), "a space")
  assertFalse(WordBreak.isWordLike(cps, 6, 7), "a comma")
  assertTrue(WordBreak.isWordLike(cps, 9, 10), "an ideograph")
  assertTrue(WordBreak.isWordLike(cps, 11, 12), "hiragana")
  assertTrue(WordBreak.isWordLike(cps, 13, 16), "Thai")
}

test "Ctrl+Right goes to the end of each word, Ctrl+Left to the start" {
  assertEqual(rightStops("one two, three"), "3 7 14", "right")
  assertEqual(leftStops("one two, three"), "9 4 0", "left")
  assertEqual(rightStops("  lead"), "6", "leading spaces are skipped")
  assertEqual(rightStops("end.  "), "3 6", "past the last word is the end of the text")
  assertEqual(leftStops("  lead"), "2 0", "before the first word is the start of the text")
}

test "a caret inside a word moves to that word's edges" {
  val cps = codePoints("alpha beta")
  assertEqualInt(WordBreak.nextWordEnd(cps, 2), 5, "to the end of alpha")
  assertEqualInt(WordBreak.previousWordStart(cps, 8), 6, "to the start of beta")
  assertEqualInt(WordBreak.previousWordStart(cps, 6), 0, "from the start of beta to the start of alpha")
  assertEqualInt(WordBreak.nextWordEnd(cps, 5), 10, "from the end of alpha to the end of beta")
  assertEqualInt(WordBreak.nextWordEnd(cps, -3), 5, "a position before the text counts as its start")
  assertEqualInt(WordBreak.previousWordStart(cps, 99), 6, "and one past its end as its end")
}

test "an empty text has no boundaries to move to" {
  val none: slice[Int] = []
  assertEqualInt(WordBreak.boundariesIn(none, 0, 0).count, 1, "one position")
  assertEqualInt(WordBreak.nextWordEnd(none, 0), 0, "right")
  assertEqualInt(WordBreak.previousWordStart(none, 0), 0, "left")
}

test "a long run of combining marks stays one word" {
  val sb = StringBuilder.new()
  StringBuilder.append(sb, "a")
  var i = 0
  while i < 20000 {
    StringBuilder.append(sb, codepointToString(0x301))
    i = i + 1
  }
  StringBuilder.append(sb, " b")
  val all = codePoints(StringBuilder.toString(sb))
  val bounds = WordBreak.boundariesIn(all, 0, all.length)
  var inside = 0
  var k = 1
  while k <= 20000 {
    if bounds[k] {
      inside = inside + 1
    }
    k = k + 1
  }
  assertEqualInt(inside, 0, "no boundary inside the letter and its marks")
  assertTrue(bounds[20001] and bounds[20002], "a boundary on each side of the space")
  assertEqualInt(WordBreak.nextWordEnd(all, 0), 20001, "Ctrl+Right goes past every mark")
}
