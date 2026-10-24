@test_module
package Ui.Native.BidiTests

import Std.Core
import Std.Collections
import Std.String
import Std.Testing
import Ui.Native.Bidi
import Ui.Native.UnicodeData

// Hebrew letters (right to left, class R), Arabic letters (AL) and Arabic-Indic digits (AN), by
// code point so that no right to left text is in this file.
val alef: String = "א"

val bet: String = "ב"

val gimel: String = "ג"

val arabicAlef: String = "ا"

val arabicOne: String = "١"

val arabicTwo: String = "٢"

val rle: String = "‫"

val pdf: String = "‬"

val lro: String = "‭"

val rli: String = "⁧"

val pdi: String = "⁩"

func levelsOf(s: String): String {
  val cps = codePoints(s)
  val levels = Bidi.resolveLevels(cps, 0, cps.length, Bidi.paragraphLevelOf(cps, 0, cps.length))
  var r = ""
  for l in levels {
    r = r + fromInt(l)
  }
  r
}

// The visual order of the characters of `s` as a line, one index per character.
func orderOf(s: String): String {
  val cps = codePoints(s)
  val para = Bidi.paragraphLevelOf(cps, 0, cps.length)
  val levels = Bidi.resolveLevels(cps, 0, cps.length, para)
  var r = ""
  var first = true
  for run in Bidi.lineRuns(cps, 0, levels, 0, cps.length, para) {
    var i = if run.level % 2 == 1 { run.to - 1 } else { run.from }
    while i >= run.from and i < run.to {
      r = r + (if first { "" } else { " " }) + fromInt(i)
      first = false
      i = i + (if run.level % 2 == 1 { 0 - 1 } else { 1 })
    }
  }
  r
}

test "the paragraph direction is that of its first strong character" {
  val abc = codePoints("abc")
  assertEqualInt(Bidi.paragraphLevelOf(abc, 0, 3), 0, "Latin")
  val heb = codePoints(alef + bet + gimel)
  assertEqualInt(Bidi.paragraphLevelOf(heb, 0, 3), 1, "Hebrew")
  val ar = codePoints(arabicAlef + "a")
  assertEqualInt(Bidi.paragraphLevelOf(ar, 0, 2), 1, "Arabic letter")
  val digitsFirst = codePoints("12 " + alef)
  assertEqualInt(Bidi.paragraphLevelOf(digitsFirst, 0, 4), 1, "digits are not strong")
  val none = codePoints("123 !")
  assertEqualInt(Bidi.paragraphLevelOf(none, 0, 5), 0, "no strong character")
  val inIsolate = codePoints(rli + alef + pdi + " abc")
  assertEqualInt(Bidi.paragraphLevelOf(inIsolate, 0, 7), 0, "text inside an isolate does not count")
}

test "needsBidi is false for left to right text and true for anything that can reorder" {
  assertFalse(Bidi.needsBidi(codePoints("hello, world 123"), 0, 16), "Latin")
  assertFalse(Bidi.needsBidi(codePoints("あ一"), 0, 2), "Japanese")
  assertTrue(Bidi.needsBidi(codePoints("a" + alef), 0, 2), "Hebrew")
  assertTrue(Bidi.needsBidi(codePoints(arabicOne), 0, 1), "an Arabic digit")
  assertTrue(Bidi.needsBidi(codePoints("a" + rle), 0, 2), "an embedding")
  assertTrue(Bidi.needsBidi(codePoints("a" + rli), 0, 2), "an isolate")
}

test "a Hebrew word in a Latin sentence is reversed in place" {
  val s = "abc " + alef + bet + gimel + " def"
  assertEqual(levelsOf(s), "00001110000", "levels")
  assertEqual(orderOf(s), "0 1 2 3 6 5 4 7 8 9 10", "order")
}

test "numbers keep their order inside right to left text" {
  val s = alef + bet + gimel + " 123 " + alef + bet + gimel
  assertEqual(levelsOf(s), "11112221111", "levels")
  assertEqual(orderOf(s), "10 9 8 7 4 5 6 3 2 1 0", "order")
  assertEqual(levelsOf(alef + bet + "12"), "1122", "digits after letters")
  assertEqual(orderOf(alef + bet + "-12"), "3 4 2 1 0", "a minus sign before digits joins them")
}

test "Arabic-Indic digits are numbers whatever the paragraph direction" {
  val s = arabicAlef + " " + arabicOne + arabicTwo
  assertEqual(levelsOf(s), "1122", "levels")
  assertEqual(orderOf(s), "2 3 1 0", "order")
  assertEqual(levelsOf("a " + arabicOne), "002", "an Arabic digit in a left to right paragraph")
}

test "neutrals between two directions take the paragraph direction" {
  assertEqual(levelsOf("ab " + alef + bet + gimel + ", cd"), "0001110000", "the comma follows the paragraph")
  assertEqual(
    levelsOf(alef + bet + gimel + ", ab"),
    "1111122",
    "a comma between Hebrew and Latin in a Hebrew paragraph"
  )
}

test "paired brackets take the direction of their contents" {
  val s = alef + bet + gimel + " (abc) " + alef + bet + gimel
  assertEqual(levelsOf(s), "1111122211111", "Latin inside brackets in a Hebrew paragraph")
  assertEqual(orderOf(s), "12 11 10 9 8 5 6 7 4 3 2 1 0", "brackets are not turned around the Latin word")
  val t = "abc (" + alef + bet + gimel + ") def"
  assertEqual(levelsOf(t), "0000011100000", "Hebrew inside brackets in a Latin paragraph")
  assertEqual(orderOf(t), "0 1 2 3 4 7 6 5 8 9 10 11 12", "the Hebrew word turns around inside its brackets")
}

test "an embedding and an override change the direction of what they hold" {
  val embedded = "a" + rle + alef + bet + pdf + "d"
  assertEqual(levelsOf(embedded), "001110", "right to left embedding")
  val overridden = "ab" + lro + alef + bet + pdf
  assertEqual(levelsOf(overridden), "000222", "left to right override of Hebrew; the PDF takes the level before it")
  assertEqual(orderOf(overridden), "0 1 2 3 4 5", "stays in logical order")
}

test "an isolate does not affect the text around it" {
  assertEqual(levelsOf("a" + rli + "b" + pdi + "c"), "00200", "left to right text inside a right to left isolate")
}

test "trailing spaces take the paragraph direction in the line" {
  val s = alef + bet + gimel + " "
  assertEqual(orderOf(s), "3 2 1 0", "the space is first on screen, at the end of the reading order")
  val t = "abc " + alef + bet + " "
  assertEqual(orderOf(t), "0 1 2 3 5 4 6", "after the Hebrew word at the end of a left to right line")
}

test "a line of a longer paragraph is reordered by itself" {
  val s = "abc " + alef + bet + gimel + alef + bet + gimel + " def"
  val cps = codePoints(s)
  val levels = Bidi.resolveLevels(cps, 0, cps.length, 0)
  val runs = Bidi.lineRuns(cps, 0, levels, 4, 10, 0)
  assertEqualInt(runs.count, 1, "one run")
  assertEqualInt(runs[0].from, 4, "from")
  assertEqualInt(runs[0].to, 10, "to")
  assertEqualInt(runs[0].level, 1, "level")
}

test "mirroring pairs the brackets and the angle quotes" {
  assertEqualInt(UnicodeData.mirrorOf(40), 41, "(")
  assertEqualInt(UnicodeData.mirrorOf(41), 40, ")")
  assertEqualInt(UnicodeData.mirrorOf(60), 62, "<")
  assertEqualInt(UnicodeData.mirrorOf(171), 187, "left angle quote")
  assertEqualInt(UnicodeData.mirrorOf(97), 97, "a letter is its own mirror image")
  assertEqualInt(UnicodeData.bracketTypeOf(91), 1, "[ opens")
  assertEqualInt(UnicodeData.bracketTypeOf(93), 2, "] closes")
  assertEqualInt(UnicodeData.pairedBracketOf(123), 125, "{ pairs with }")
}

test "the character properties are Unicode 15.1" {
  assertEqualInt(UnicodeData.bidiClassOf(97), 0, "a is L")
  assertEqualInt(UnicodeData.bidiClassOf(1488), 1, "alef is R")
  assertEqualInt(UnicodeData.bidiClassOf(1575), 13, "Arabic alef is AL")
  assertEqualInt(UnicodeData.bidiClassOf(1633), 5, "Arabic-Indic one is AN")
  assertEqualInt(UnicodeData.bidiClassOf(48), 2, "0 is EN")
  assertEqualInt(UnicodeData.bidiClassOf(32), 9, "space is WS")
  assertEqualInt(UnicodeData.bidiClassOf(9), 8, "tab is S")
  assertEqualInt(UnicodeData.bidiClassOf(8294), 20, "LRI")
}

// The text of a vector is "paragraph level|code points in hex|levels|visual order", made by running
// ICU and FriBidi on the same text (the order is the one both give; the levels are FriBidi's, with
// x for a character rule X9 removes).  Only the paragraph level and the visual order are checked.
func hexValue(s: String): Int {
  val cps = codePoints(s)
  var v = 0
  var i = 0
  while i < cps.length {
    val c = cps[i]
    v = v * 16 + (if c >= 65 { c - 55 } else { c - 48 })
    i = i + 1
  }
  v
}

func decValue(s: String): Int {
  val cps = codePoints(s)
  var v = 0
  var i = 0
  while i < cps.length {
    v = v * 10 + (cps[i] - 48)
    i = i + 1
  }
  v
}

func vectorProblem(v: String): String {
  val f = split(v, "|")
  val para = decValue(f[0])
  val acc: List[Int] = newList()
  for part in split(f[1], " ") {
    acc.add(hexValue(part))
  }
  val cps = acc.toArray()
  val n = cps.length
  if Bidi.paragraphLevelOf(cps, 0, n) != para {
    return "paragraph level"
  }
  val removed = codePoints(f[2])
  val levels = Bidi.resolveLevels(cps, 0, n, para)
  var got = ""
  var first = true
  for run in Bidi.lineRuns(cps, 0, levels, 0, n, para) {
    var i = if run.level % 2 == 1 { run.to - 1 } else { run.from }
    while i >= run.from and i < run.to {
      if removed[i] != 120 {
        got = got + (if first { "" } else { " " }) + fromInt(i)
        first = false
      }
      i = i + (if run.level % 2 == 1 { 0 - 1 } else { 1 })
    }
  }
  if got != f[3] {
    return "order " + got + " not " + f[3]
  }
  ""
}

val vectors: List[String] = ["0|3E 31 202D 5B 25 62 661 61 628 2C 31 9 3F|00x2222222202|0 1 3 4 5 6 7 8 9 10 11 12", "0|200E 200F 2D 61C 20 661 5D0 663|01111212|0 7 6 5 4 3 2 1", "0|2066 202E 5D1 6F1 2067 232A 2068 20 3008 62 3008 7D 20|0x33355666660|0 7 8 9 10 11 6 5 4 3 2 12", "1|20 628 32 20 2F 7D 3F|1121111|6 5 4 3 2 1 0", "1|629 661 2068 61 5D0 31 7D 2D 5B0 3F A0 20 32 2E|12123433333342|3 12 11 10 9 8 7 6 5 4 13 2 1 0", "1|661 5D1 31 2B 202A A0 5B0 5D2 200E 2C 31 62 2E 32 660 3009|2121x22322222242|5 6 7 8 9 10 11 12 13 14 15 3 2 1 0", "1|627 202A 2069|1x1|2 0", "1|628 3008 2C 5D0 3009 20 202A|111111x|5 4 3 2 1 0", "1|6F1 3C 5D 21 202D 61C 24 202A 20 5D1 3009 21|2111x22x4544|5 6 8 9 10 11 3 2 1 0", "1|25 7D 2D 200F 2C 32 628 28 7B 5B|1111121111|9 8 7 6 5 4 3 2 1 0", "1|5D1 2F 627 A0 2329 661 2F 2067 31 2F 61 2F|111112114343|11 10 9 8 7 6 5 4 3 2 1 0", "0|2067 202A 2E 2068 629 A0 32 7D 3E 2F 661 232A 5B0 627 25|0x2233433343333|0 2 3 14 13 12 11 10 9 8 7 6 5 4", "1|7D 7D 232A 21 28 28 22 29 661 232A 200F|11111111211|10 9 8 7 6 5 4 3 2 1 0", "1|2B 61C 9 22 627 61C 2C 32 202B 3E|11111112x3|7 9 6 5 4 3 2 1 0", "0|24 2C 660 61|0020|0 1 2 3", "1|5D1 62 5D2 32 62 22 3009 629|12122111|7 6 5 3 4 2 1 0", "1|5D0 21 22 24 31 5B0 3C 7B 63 629 2B 31|111222112112|11 10 9 8 7 6 3 4 5 2 1 0", "1|5D0 22 29 5D1 202A 64B 628|1111x23|5 6 3 2 1 0", "0|232A 2068 61C 2329 202B 62 61 662 20 629 31 202E 2C 9 661|0011x444334x505|0 1 10 12 9 8 5 6 7 3 2 13 14", "0|5B 2066 3A 5D1 2066|00230|0 1 2 3 4", "1|3C 232A 29 627 232A 33 31 2D 33 23 202A 31 2329 5B 3A 20|1111122121x22221|15 11 12 13 14 9 8 7 5 6 4 3 2 1 0", "0|232A 2067 5D0 662 32 628 202C 663 2B 627 2066 3F 62 3C 200E|001221x21112222|0 1 11 12 13 14 10 9 8 7 5 3 4 2", "0|3C 200E 33 7B 3F 2068 20 3008 660|000000224|0 1 2 3 4 5 6 7 8", "1|29 232A 627 2067 62 232A 3008 33 61C 232A|1111433433|9 8 7 6 5 4 3 2 1 0", "1|202B 2B 6F1 628 33 200F 2F 2E 9|x34343331|8 7 6 5 4 3 2 1", "0|6F1 2069 2329 202B 2C 5B0|000x11|0 1 2 5 4", "0|202A 63 3A 29|x222|1 2 3", "0|62 5D0 61 31 5D1 2066 31 20 61 200E 202E 33 2329 202B 62 2C|0100102222x33x65|0 1 2 3 4 5 6 7 8 9 15 14 12 11", "1|3C 2329 32 5D0 61C 28 627 23 9 32 660 627 20 62 62|112111111221122|13 14 12 11 9 10 8 7 6 5 4 3 2 1 0", "0|61 5D0|01|0 1", "1|232A 202A 2D 20 200F 22 5D2 31|1x223334|2 3 7 6 5 4 0", "1|627 61 2066 2F 629 28 663 202B 32 25 33 5B0 24 202E|1212334x44444x|3 6 8 9 10 11 12 5 4 2 1 0", "0|61 5D2 5B|010|0 1 2", "0|28 2068 5D0 A0 20 3F 202E 20 660 64B 3E|001111x3333|0 1 10 9 8 7 5 4 3 2", "0|25 29 61 2068 32 32|000022|0 1 2 3 4 5", "0|2329 200E 5B0 628 7B A0 23 663 2067 300 2E 2067 2F 202B|0001111201113x|0 1 2 7 6 5 4 3 8 12 11 10 9", "1|32 2D 20 31 663 200F 627 7B 2C|211221111|8 7 6 5 3 4 2 1 0", "0|62 202E 7B 2066 28|0x112|0 4 3 2", "1|5D0 5D1 2D 9 61|11112|4 3 2 1 0", "1|2069 300 202D 20 31 662 64B 5D0 5D 663|11x2222222|3 4 5 6 7 8 9 1 0", "1|7D 2066 2069 5D0 61 5D0 2D 31 20 5D0 2067 663 2E 20|11112112111431|13 12 11 10 9 8 7 6 5 4 3 2 1 0", "1|2069 3A 20 300 3008 5D0 31 3A|11111121|7 6 5 4 3 2 1 0", "0|2C 202D 5B 3E 662 2C 31|0x22222|0 2 3 4 5 6", "0|2068 2329 628 3A 3F 32 61C 7D 20 202E|011112110x|0 7 6 5 4 3 2 1 8", "0|663 2066 5D1 2066 3008 33 29 21 7D 20 2069|20324444400|0 1 2 3 4 5 6 7 8 9 10", "1|5D 232A 627 28|1111|3 2 1 0", "0|202D 20 63 5D 627 24 33 2C 62 200F 2C 33 5B0 32|x2222222222222|1 2 3 4 5 6 7 8 9 10 11 12 13", "1|5D 23 24 5D2 5D1 20|111111|5 4 3 2 1 0", "0|2066 31 663 5D0 300 28 20|0243320|0 1 4 3 2 5 6", "0|661 33 23 20 200E 2E 3C 24 2066 25 2068 5D 28 7B 3C 5D1|2000000002233333|0 1 2 3 4 5 6 7 8 9 10 15 14 13 12 11", "0|24 5D 33 32 202D 9 61 22 202A 3009 2D 2067 232A 2D 63 2F|0000x022x4445565|0 1 2 3 5 6 7 9 10 11 15 14 13 12", "1|202C 21 61C 7D 5D2 2B 31 202E 22 62 31 660|x111112x3333|6 11 10 9 8 5 4 3 2 1", "0|660 202E 2067 6F1 3A 61C 300 2D 61C 2C 64B 2069 3008 28|2x143333333111|13 12 11 10 9 8 7 6 5 4 3 2 0", "0|5B0 61 5D2 7D 23 33 2067 3A 662 2F 2E 627 202E 23 32 663|001122012111x333|0 1 4 5 3 2 6 15 14 13 11 10 9 8 7", "1|5B0 33 5D1 23 2F 24 5D 661 661 2329 31 3F 62 232A|12111112212121|13 12 11 10 9 7 8 6 5 4 3 2 1 0", "1|200F 300 32 9 3A 202E|11211x|4 3 2 1 0", "1|627 61C 3A 660 5D 5D0 5D1|1112111|6 5 4 3 2 1 0", "0|661 33 62 629 5D0|20011|0 1 2 4 3", "0|2067 660|02|0 1", "1|5B 202E 20 663 200F 64B 200F 628|1x333333|7 6 5 4 3 2 0", "1|628 2329|11|1 0", "0|2068 629 31 25 232A 21 628 61 31|012111122|0 7 8 6 5 4 3 2 1", "1|7B 24 5D2 661 627 662 2B 24 202C 32 202E 7D 32 627 2069|11121211x2x3331|14 9 13 12 11 7 6 5 4 3 2 1 0", "1|9 5D2 22 20 202C 3009 5D1 2067 202C 7B 2B 5D1 202E 29|1111x111x333x5|13 11 10 9 7 6 5 3 2 1 0", "0|62 2C 3A 3E 20 2067 3008 663|00000012|0 1 2 3 4 5 7 6", "0|2C 3E 202A 5B0 660 202A 62 62 3008 2068 3F 5B 5D 24 23|00x24x444466666|0 1 3 4 6 7 8 9 10 11 12 13 14", "1|627 202B 628 29 5D0 9 22 5D 5B0 660 62 629 6F1 2067|1x333133344341|13 12 11 9 10 8 7 6 5 4 3 2 0", "1|31 5D0 7D 25 3C 20 7D 2C 3F 21 627 20|211111111111|11 10 9 8 7 6 5 4 3 2 1 0", "1|627 25 2E 32 7D 2B|111211|5 4 3 2 1 0", "1|2B 628 21|111|2 1 0", "1|3F 3008 627 2068 20 202B 627 300 2F 2B 61C 202E 3009|11113x55555x7|12 10 9 8 7 6 4 3 2 1 0", "1|202C 20 5D0 2E 627 31 3C 5B 200F 61 628 61 5D0|x111121112121|12 11 10 9 8 7 6 5 4 3 2 1", "1|660 5D0 2B 62 202E 627 61C 2066 7D 64B A0 3F 7B|2112x33344444|3 8 9 10 11 12 7 6 5 2 1 0", "0|7B 300 64B 29 2F 20 3E 200E 24 5D0 202B 61C 9 202E 2D 202B|0000000001x10x3x|0 1 2 3 4 5 6 7 8 11 9 12 14", "1|202D 627 662 3E 5D0 200F 2B 61 2B 2B 5D0 3009 9 5D0|x2222222222212|13 12 1 2 3 4 5 6 7 8 9 10 11", "1|3009 629 202E 28 300 31 22 A0|11x33333|7 6 5 4 3 1 0", "1|28 20 627 629 2067 2B 20 2C 3A 31|1111133334|9 8 7 6 5 4 3 2 1 0", "1|5D1 5D 5D1 660 202C 3F 2E 9 662 61C A0 32 2E 202D 61 20|1112x11121121x21|15 14 12 11 10 9 8 7 6 5 3 2 1 0", "0|232A 5B0 200E 23 200E 31 202A 20 3A 3A 3009 20 61 5D2 2E|000000x22222232|0 1 2 3 4 5 7 8 9 10 11 12 13 14", "0|61 23 660 2067 5D1|00201|0 1 2 3 4", "0|5B0 29 29 6F1 32 2066|000000|0 1 2 3 4 5", "1|202C 61C 61 300 202A 5D0 5D0 33 9 662 20 22 31|x122x33414334|12 11 10 9 8 2 3 7 6 5 1", "1|5D 24 627 5D1 23 2E 5B 62 2C 627 32 5D0|111111121121|11 10 9 8 7 6 5 4 3 2 1 0", "1|7B 6F1 9 20 2B 6F1 628 3C 627 202D|121112111x|8 7 6 5 4 3 2 1 0", "1|202B 628 2C 200F 7D 9 5D0 7D 627 202B 61C|x33331333x5|10 8 7 6 5 4 3 2 1", "1|202D 202A 20 20 61C|xx445|2 3 4", "1|28 629 62 2C 3F 22 23 2F 627 5D1 5D0 63 9 232A 628|112111111112111|14 13 12 11 10 9 8 7 6 5 4 3 2 1 0", "0|33 202D|0x|0", "1|20 7B 5D1 2D 5D0 3F 662|1111112|6 5 4 3 2 1 0", "1|32 7D 5D1 24 9 2E 6F1|2111112|6 5 4 3 2 1 0", "1|2E 5D1 202D 2C 3A 7B 5B 629 3009 663 31 29 5B 61|11x22222222222|3 4 5 6 7 8 9 10 11 12 13 1 0", "1|32 9 29 9 20 2B 61C 24|21111111|7 6 5 4 3 2 1 0", "0|3009 62 200E 660 628 2B 2F 31 3008 663 2068 62 64B 20|00021112120220|0 1 2 9 8 7 6 5 4 3 10 11 12 13", "0|20 3F 2D 202E 2068 3C 300 32 2C 232A 7B|000x1222222|0 1 2 5 6 7 8 9 10 4", "1|2F 22 2F 5D1 232A 20 663 5D1 663 5D0|1111112121|9 8 7 6 5 4 3 2 1 0", "1|202B 5D1 5B 661 29 2B 7B 202A|x334333x|6 5 4 3 2 1", "1|202B 5B 5D0 33 2069 202A 3008|x3343x4|6 4 3 2 1", "0|63 5B0 3009 627 2329 629 32|0001112|0 1 2 6 5 4 3", "1|61C 22 21 2B 2066 20 61C 663 5D2|111112343|5 8 7 6 4 3 2 1 0", "1|5D1 628 627 660 202B 2066 663 2C 3F 2066 3009 202A 200F|1112x364446x9|3 6 7 8 9 10 12 5 2 1 0", "1|627 5D0 202E 660 5B 2068 5D1 5D0 5D2 3C 5B0 3E 62|11x3335555556|12 11 10 9 8 7 6 5 4 3 1 0", "1|A0 28 661 64B 627 5D0 662 21 628 32 3F|11221121121|10 9 8 7 6 5 4 2 3 1 0", "0|6F1 5B0 2068|000|0 1 2", "0|7B 2D 2068 31 21 21 3F 2B|00022222|0 1 2 3 4 5 6 7", "1|29 2069 2E 31 61C 663 20 2066 62|111212112|8 7 6 5 4 3 2 1 0", "0|662 2F 662 2066 202B 32 23 25 32|2220x4444|0 1 2 3 5 6 7 8", "1|2F 33 5D1 21 33 7B 32 5B0 202B 24 31 20 3008 202B 3C|12112122x4433x5|6 7 14 12 11 9 10 5 4 3 2 1 0", "0|32 24 202A 661 61 627 25 2B 5D2 660 202E 200F 63 A0 661|00x4233334x3333|0 1 3 4 14 13 12 11 9 8 7 6 5", "1|3E 5D 5D1 202D 24 24 663 232A 3008|111x22222|4 5 6 7 8 2 1 0", "1|61C 660 23 627 2069|12111|4 3 2 1 0", "1|3008 3008 661 627 A0 20|112111|5 4 3 2 1 0", "1|202B 32 2329 232A 300 627 29 5D2|x4333333|7 6 5 4 3 2 1", "1|5D2 3C 200F 5D 628 5D 2329 2329 300 2069 5B0|11111111111|10 9 8 7 6 5 4 3 2 1 0", "1|33 3C 6F1 627 20 23 31 5B0 628 202E 6F1 5B0 61|212111221x333|12 11 10 8 6 7 5 4 3 2 1 0", "1|5D2 7D 61C 5D 628 20 63 202C 202B|1111112xx|6 5 4 3 2 1 0", "0|9 29 63 5D0 32 31 2E 202A 21 61C 5D0|0001220x233|0 1 2 4 5 3 6 8 10 9", "0|9 61 2066 627 202A 5D 6F1 232A|0003x444|0 1 2 5 6 7 3", "0|2329|0|0", "0|61 31 232A 24 24 660 5B0|0000022|0 1 2 3 4 5 6", "1|627 2F 20 31 2067 20|111211|5 4 3 2 1 0", "1|28 232A 28 627 61|11112|4 3 2 1 0", "0|9 663 662 23 61 6F1 25 32 20|022000000|0 1 2 3 4 5 6 7 8", "1|5D1 32 3008 61C 28 202B 2D 660 5D0 3C 20 7D 20 200F 5D1|12111x343333333|14 13 12 11 10 9 8 7 6 4 3 2 1 0", "0|2329 202C 202E|0xx|0", "1|20 628|11|1 0", "0|3009 2069|00|0 1", "0|63 3008 5D0 2D 5D2 29 28 200E 20 A0|0011100000|0 1 4 3 2 5 6 7 8 9", "0|2B 3E 29 20 2B 3008 660 22 61 62 24 31 627 7D|00000020000010|0 1 2 3 4 5 6 7 8 9 10 11 12 13", "0|2067 200E 5D2 20 62 202A 9 9 2067 202C 33 5B0 3E 627 3F|02112x002x44333|0 4 3 2 1 6 7 8 14 13 12 10 11", "0|3A 33 232A 3C 3F 202B 2E 64B 300|00000x111|0 1 2 3 4 8 7 6"]

test "random text is reordered as ICU and FriBidi reorder it" {
  var bad = 0
  var first = ""
  for v in vectors {
    val p = vectorProblem(v)
    if p.length > 0 {
      bad = bad + 1
      if first.length == 0 {
        first = v + " :: " + p
      }
    }
  }
  assertEqual(first, "", "first disagreement")
  assertEqualInt(bad, 0, "disagreements")
}
