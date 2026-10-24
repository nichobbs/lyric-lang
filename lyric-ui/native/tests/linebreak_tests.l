@test_module
package Ui.Native.LineBreakTests

import Std.Core
import Std.Collections
import Std.String
import Std.Encoding.{codepointToString}
import Std.Testing
import Ui.Native.LineBreak

// `s` with a bar at every position where a line may break (not at either end).
func marked(s: String): String {
  val cps = codePoints(s)
  val breaks = LineBreak.breaksIn(cps, 0, cps.length)
  var r = ""
  var i = 0
  while i < cps.length {
    if i > 0 and breaks[i] != LineBreak.noBreak {
      r = r + "|"
    }
    r = r + codepointToString(cps[i])
    i = i + 1
  }
  r
}

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

func cpsOfHex(s: String): slice[Int] {
  val acc: List[Int] = newList()
  for part in split(s, " ") {
    acc.add(hexValue(part))
  }
  acc.toArray()
}

// The same for code points given in hex, as `1F1E6 1F1E7|1F1E8`.
func markedHex(s: String): String {
  val cps = cpsOfHex(s)
  val breaks = LineBreak.breaksIn(cps, 0, cps.length)
  var r = ""
  var i = 0
  while i < cps.length {
    if i > 0 {
      r = r + (if breaks[i] != LineBreak.noBreak { "|" } else { " " })
    }
    r = r + upperHex(cps[i])
    i = i + 1
  }
  r
}

func upperHex(v: Int): String {
  val digits = "0123456789ABCDEF"
  if v == 0 {
    return "0"
  }
  var n = v
  var r = ""
  while n > 0 {
    r = substring(digits, n % 16, 1) + r
    n = n / 16
  }
  r
}

test "a line may break after spaces, and the spaces stay with the word before" {
  assertEqual(marked("hello world foo"), "hello |world |foo", "words")
  assertEqual(marked("a   b"), "a   |b", "a run of spaces")
  assertEqual(marked("abc"), "abc", "one word")
}

test "a line may break after a hyphen" {
  assertEqual(marked("well-known"), "well-|known", "hyphen-minus")
  assertEqual(marked("a‐b"), "a‐|b", "hyphen")
}

test "closing punctuation does not start a line, opening punctuation does not end one" {
  assertEqual(marked("word, next"), "word, |next", "comma")
  assertEqual(marked("(a) b"), "(a) |b", "parentheses")
  assertEqual(marked("a )"), "a )", "a space before a closing bracket")
  assertEqual(marked("( a"), "( a", "a space after an opening bracket")
  assertEqual(marked("x ( a"), "x |( a", "a break before the opening bracket")
  assertEqual(marked("what? yes!"), "what? |yes!", "exclamation marks")
}

test "ideographs break between characters, with the kinsoku rules" {
  assertEqual(marked("漢字仮名"), "漢|字|仮|名", "kanji")
  assertEqual(marked("漢、字"), "漢、|字", "an ideographic comma stays on its line")
  assertEqual(marked("漢「字」"), "漢|「字」", "a corner bracket opens a line but does not end one")
  assertEqual(marked("あぁ"), "あぁ", "a small kana does not start a line")
  assertEqual(marked("あー"), "あー", "nor does the prolonged sound mark")
  assertEqual(marked("あ々"), "あ々", "nor an iteration mark")
}

test "numbers keep their separators, prefixes and suffixes" {
  assertEqual(marked("1,000.50"), "1,000.50", "separators")
  assertEqual(marked("$100"), "$100", "a prefix")
  assertEqual(marked("(100)"), "(100)", "brackets")
  assertEqual(marked("10%"), "10%", "a suffix")
  assertEqual(marked("a 100"), "a |100", "a number after a space")
}

test "a break follows a slash before a letter, and a dot joins" {
  assertEqual(marked("a/b"), "a/|b", "slash")
  assertEqual(marked("http://example.com/path"), "http://|example.com/|path", "a web address")
}

test "no-break and zero width characters" {
  assertEqual(marked("a b"), "a b", "no-break space")
  assertEqual(marked("a⁠b"), "a⁠b", "word joiner")
  assertEqual(marked("a​b"), "a​|b", "zero width space")
}

test "combining marks stay with their base" {
  assertEqual(marked("é x"), "é |x", "a mark and a space")
  val cps = codePoints("é")
  assertTrue(LineBreak.joinsPrevious(cps, 1), "the mark joins the letter")
  assertFalse(LineBreak.joinsPrevious(cps, 0), "the letter joins nothing")
}

test "regional indicators pair up into flags" {
  assertEqual(markedHex("1F1E6 1F1E7 1F1E8 1F1E9"), "1F1E6 1F1E7|1F1E8 1F1E9", "two flags")
  assertEqual(markedHex("1F1E6 1F1E7 1F1E8"), "1F1E6 1F1E7|1F1E8", "an odd one out")
}

test "Hangul syllables break between blocks only" {
  assertEqual(markedHex("D55C AE00"), "D55C|AE00", "two syllable blocks")
  assertEqual(markedHex("1112 1161 11AB"), "1112 1161 11AB", "a conjoining jamo sequence")
}

test "emoji modifiers stay with their base" {
  assertEqual(markedHex("1F466 1F3FB 1F466"), "1F466 1F3FB|1F466", "a skin tone")
}

test "quotation marks keep to the text they quote" {
  assertEqual(marked("a “b c” d"), "a |“b |c” |d", "curly quotes")
  assertEqual(marked("a “ b"), "a |“ b", "an opening quote holds the spaces after it")
  assertEqual(marked("a \"b\" c"), "a |\"b\" |c", "straight quotes")
}

test "a space before a comma and a number is a break" {
  assertEqual(marked("a ,5"), "a |,5", "the comma starts a number")
  assertEqual(marked("a ,b"), "a ,b", "else a comma never starts a line")
}

test "a line feed forces a break and the end of the text is one" {
  val cps = codePoints("a\nb")
  val breaks = LineBreak.breaksIn(cps, 0, 3)
  assertEqualInt(breaks.count, 4, "one entry per position")
  assertEqualInt(breaks[0], LineBreak.noBreak, "never at the start")
  assertEqualInt(breaks[1], LineBreak.noBreak, "not before the line feed")
  assertEqualInt(breaks[2], LineBreak.breakRequired, "after it")
  assertEqualInt(breaks[3], LineBreak.breakRequired, "at the end")
  assertEqualInt(LineBreak.breaksIn(cps, 0, 0).count, 1, "empty text")
}

test "a range of a longer text is analysed by itself" {
  val cps = codePoints("xx foo bar yy")
  val breaks = LineBreak.breaksIn(cps, 3, 10)
  assertEqualInt(breaks.count, 8, "one entry per position of the range")
  assertEqualInt(breaks[4], LineBreak.breakAllowed, "after foo and the space")
}

// A vector is "code points in hex|breaks by libunibreak|breaks by ICU": one 0 or 1 for each position
// between two characters.  These are the vectors both agree on.
func gotBits(cps: slice[Int]): String {
  val b = LineBreak.breaksIn(cps, 0, cps.length)
  var s = ""
  var i = 1
  while i < cps.length {
    s = s + (if b[i] == LineBreak.noBreak { "0" } else { "1" })
    i = i + 1
  }
  s
}

val vectors: List[String] = ["7E 21 7B A2 7E 62|01000", "20 7D 2060 AC00 2028 2028 A2 2014 AC01 20AC 4E00 2030 200B|000011111000", "A 9 28 5D1 AD 2060 21 29 1F1E6 2010 22 200B 300 D 7E 3D|110000010001010", "20 1161 28 2060 24 20AC 29|110010", "7B 3A 20 A0 2F 85 85 62|0010011", "FFFC 32 31 20 AD|1001", "AC00 2B 1F466 2030 62 2060 2028 5F 31 3B|100000100", "AC00 3B 2010 32 32 200D 1F1E7 1F3FB 3005 4E00 3005 AC00 3B 7D 20|00100010101000", "62 5F 7B 2764 5D 20 5D 1161 5D 61 3C FFFC 2024 28 31|00000010001110", "2032 1100 FFFC 300 25 A2 3E 200D 2060 61 AC01 31|11011000011", "20 3D 20AC 1F1E6 FFFC 7D 5F 23 D|10110100", "23 27 61 20 5D 5D1 3F 61 300 1161 2D A2 25 11A8 20|00000010101110", "1F3FB 1F1E7 2014 1F466 300 61 200D 20 63 A 31 5B 5B 2D 2028 25|111010010100001", "1F3FB 2032 2764 2D 3B 9 1161 1F600 2024 2764 61 20 85 3B 200D|01000110110010", "5D1 33 A2 23 62 3005 21 1161 28 A2 2032 21 A0|000000110100", "5B 85 20 20 3D 62|01010", "3B 2E 21 1F1E7 300 3C 3F D 5D0 20|001010010", "61 A0 21 1F466 300 2C 1F600 3001 23 62 4E00 2764 2014 2D 5F|00100101011101", "5D1 3A 63 62 24 A0|00000", "300 A0 1F600 5F AC01 4E00 9 2D A2 2F 2030 85 AC01|001110010101", "2014 29 5D 7E 2028 A 5D0 3C 3A 2028 7B 63 1F3FB|000011000101", "11A8 2010 61 B0|010", "A0 1F466 7E A0 2764 200B|01000", "3A 20 2764 1F1E7 2A 1F3FB 32 33 61 2764 33 3042 5D1 D 7E|01111100111101", "3005 27 4E00 9|000", "25 3005 3B 22 85|0000", "3005 20AC 29 5F 9|1000", "3005 63 62 33 21 3042 A 2A 2030 20 85 1F1E6 2060 63 20AC AC00|100010100010000", "63 62 7B 2A D 3A AC01 32 AC01 23 3005 1F1E6|00001111101", "5B 22 27 D 7B 9 2028|000100", "7D 2764 200B 2013 24 31 61 2D|1011000", "AD 33 2F 33 3C 27 26 1100 2013 2010 20 2010 7B 24 3042 29|100000100011000", "62 AD 5D1 9 11A8 85 1F600 1F3FB 200D 24 23 2060 5D 29 23|01000110000000", "2A B0 5D AC00 5B 2028 61 2D 20|00110100", "1F600 21 31 2060 D 5F 2028 300 27 2F|010010100", "2024 61 32 20AC|100", "200D 20 2C 1F600 62 2032 2030 31 33 20 AC01 2032 1F1E6 3E|0011010001011", "2028 5B 200D 1100 2B|1001", "7B 2C 3C 26|000", "3B 4E00 1161 62 200D|1110", "25 1F466 21 1F1E6|101", "29 4E00 5F 2A|110", "1F3FB 63 2032 21 27 3A 7B 24 4E00 61 2010 1F3FB 1161|100001001011", "7B 20 FFFC 3B AC00 2A 7D 2D 61 1F3FB FFFC 2028 62 1F1E7|0001100111011", "3E 2E 1F1E6 3F 2E 22 2C 2030 31 2030 300 62 3D 20 27 61|010000100000010", "AC01 1F600 26 3E B0 1F1E6 A 61 24|11001010", "11A8 62 63 61 21 9 3A 20|1000000", "3F 21 11A8 29 3C 9 1F1E6 2028 2C|01000101", "4E00 5D 3A 1F466 2014 1F1E7 20AC 2013 2764 26 1F3FB 2030 7E|001111011100", "7B 3C 61 2014 85 2D 5B 21 B0 5F 33 61|00101101000", "3B A2 61 1F3FB 28 2D 2E 2060 3001 200B 61 200D 5B 28 2013|10110000010000", "1161 1F1E7 3E 2D AC00 3F A3 9 5D 22 26 7D|11010100000", "3D 5D1 5F A 3005 2013 2D 3B 20 7E 21|0001000010", "3B 7B 2C 2B AC00 1F1E7 1F1E7 2013 5D FFFC 3D 2014|10101000111", "1F3FB 7B FFFC 2014 5B 20 AC00 62 3042 3042 2013 2E|10110011100", "FFFC 20AC 61 62 21 1100 29 32 7D 2014 61 2D 61 2032 3D 1F466|100010001101001", "200D 3C 1100 5B 2030 AC00 1F1E7 2D 2060 2060 2030 7D 7D|011011000000", "61 28 7B 2A B0 31 A2|000000", "2024 7B 9 3B 62 2010 7B FFFC 9 29|100001010", "26 AD 62 61 27 85 20 27 3001 2F 7E 2E A 20 5B 9|010001100100110", "5D 85 62 3C 62 11A8|01001", "D 1F466 61 2B 3C 1F1E7 3042 2A 20 2010 3B 3A 62 A|1100111010000", "11A8 3005 2028 3B 5D 61 5F 2010 5D0|00100001", "2E 20 1161 B0|010", "61 5D1 9 1F3FB 3005|0000", "62 5D 22 2E 11A8 2010 7D 61 61 5D 20 3E 1F1E7 2764|0001001000111", "4E00 1F466 63 2024 85 AC00 AC01 3A 3A 4E00 20 62 20 2E|1100110010100", "7E 31 FFFC A3 1F3FB 27 61|011000", "200D 21 11A8 61 3A|0110", "D 20 2032 9 1161 23|11011", "1100 20 21 3C A2|0010", "3F 2A 29 62 4E00|1001", "2030 24 2024 24 300 2010 5D1 3001 2014 1F466 1161 3042 5B A0 31 29|101001011111000", "2060 5F 63 3042 7B 1F3FB A 7B 1F466 27 2D 3E 24|001100100010", "A3 AC00 5B 3F 5F 26 3A 2C 1F466 D 20 23|01010001011", "3C 2014 2030 1161|111", "200B 2028 5D0 20 3005 20AC 62 2C 2764 AD 1100 20 2C A2 1F1E7|01011001010011", "29 26 2D 2060 AC00 29 5D 5B AC00 28 2A 5D0 1F1E7 5B|0000001010011", "33 62 A 3001 21 4E00 3042 62 2014 1F1E7 1100 28 3A|001011111110", "2032 A0 1F3FB 9 1F3FB 3005 1F1E7 2060 2E 2A|000101000", "3E 5D1 2013 7E 26 27 3005 20|0000000", "2D 2028 61 2010 21 26 62 21 7B A0 5D0 1100 9 2764 9|01001001001010", "3E 26 300 25 200D B0 2028 11A8 3001 5D1 B0 AD 4E00|000000101001", "3042 3005 3005 B0 3D 20AC 1F1E7|001001", "61 33 20AC 3C 23 2030 1F1E6 A0 5B 22 62 20AC 1F1E7|000001000001", "AC00 A2 3D 1161 2030 2032 2060 5D0 27 62 3F 2D 9 200D|0010100000000", "AC00 27 1F1E6 11A8 2F 7D A0 A3 20AC 2060 61 26 27 1100 28 2028|001000010000010", "3E 7E 61 24 1F600 200D 3005 A2 32 1F600 21 1F600 7D 2C 3005|00000010101000", "32 2030 61 4E00 300 7B|00101", "2010 AC00 1F1E6 61 2014 2A 20|111110", "2028 A0 4E00 7E 1F1E6 3042 24 200B 5D0 62 300 A3 27|101111010000", "27 3005 85 3001 5B 2764|00110", "A2 3B 3B 5D1 FFFC 28 AD 85|0001100", "5D1 5D 2D 3F 20AC 27 20 20 2028 2F 2B 2030 B0 3E 2024|00010000111100", "1100 1F1E7 27 22 20AC|1000", "26 7E 2F 200B|000", "3001 3B 1F3FB 26 2764 11A8 1100 3005|0111110", "3D 21 29 3D 2E 2030 61 3E 7B 9 5D AC00 A3 2D 2024 200B|000010000011000", "2014 32 26 AC00 25 3E 2060 1100 1F3FB 63 5D 2014 3E 2A 2A|10100001101100", "2764 A 2F AC01 3F 200D 24 200B|0110000", "23 28 1100 5D1 22 29 3005 2D 33 2032 61|0010000000", "5D 2764 5B 5D|110", "2A 5B 61 62 7D 5D0|00001", "D 200D 3A AD 20 9|10001", "A2 62 2F 3D 300 26 61 2032 7E|00100000", "200D 1F466 1F600 21 24 29 3A 20 20AC A3 4E00 3005 2C AC01|0101000110001", "2D 11A8 24 7D 7D|1100", "33 FFFC A0 2D 3F 2010 2032 2032|1000011", "FFFC 3C 300 3E 5D1 28 3B 20AC 24 21 AC00 26 2060 1161 5D1 FFFC|100000110110011", "62 3D 2D 3005 A0 5F 3001 7D 63 2D 26 1F1E7 AC01 3A 20 300|000000010111001", "1F466 3A 24 3D 5D 2010 85 2030|0100001", "3005 2032 21 63|101", "1F466 FFFC 7B 2764 3B AD|11000", "3042 25 20 1161 62 A3 22 4E00|0011000", "AC01 5B 2A FFFC 62 4E00 20AC AC01 26 1100 B0 33 32 2F 22|10111101100000", "3D A 3005 2010 7B 2E 5F 5D 3D 1F600 2B 2013 24|010100001101", "61 AC00 2028 7B 7B 62 A 3D 22 1F600 5B 3D 28 B0|1010001001000", "32 2764 3D 85 5F 1100 27 5B 63 62 1F1E7 5D0 2014 1F1E7|1101100001111", "5D1 7B 1F600 A2 3005 25 A0 20 2030 22 2E 3042 7B 2014 85|00001001001100", "1161 2D 3B 5F 29|0000", "1100 29 2024 23 5B 20 7B 3A A3 2014|001000011", "62 62 2A 2A 2013|0000", "31 5D1 7B A2 61 62 FFFC 31 AC00 2E 31 28 32 63 25 3001|000001110000000", "3D 2764 A3 63 31 3001|11000", "2A 1F600 7B 20 25 2014 62 5D0|1100110", "3A 61 61 1F1E6 AD 2028 5D1 FFFC 25 1161 3B 5D0 3B 2F 2028 3E|001001111000001", "FFFC A2 2032 7D 3C|1101", "1F1E6 25 5F 20AC 1100 2028 2D 7B 26|10000110", "7B 300 A 5B 1161 62|00101", "20 3B 1F3FB 62 3C 62 200D 63 3042 5D0|011000011", "31 2C AC00 2C FFFC 25 3005 A 29 3E 20AC 62 7D 200B 200D|01011001000001", "2B 1F600 26 FFFC 20 2D 3F 200D 7B AD|011010000", "62 63 7B 32 7B 2010 20 32 A0 2030 4E00 FFFC B0 27|0000001001110", "B0 9 22 31 5F 85 2764 9 29 1F466 7B D 32 AD|0000010011010", "5B 5D 11A8 7D 2013 2028 D 20 20AC A3|010001111", "3B 3B AD 5B 2B 2764 3F 5F|0010001", "3E 3C 1F1E6 A0 26 5D1 5B 20 1100 20 61 2B 1161 3B 2764|01000000010001", "3005 2013 3001 FFFC 9 1F1E6 22 5D1 2024|00111000", "2024 3B 2010 3F 3001 27 32 A2 11A8 3F 2013 27|00000001000", "62 AC00 62 31 1F3FB 2013 1F3FB 3A 1F466 2014 28 A3 22 FFFC AC01|11010101110001", "2B 62 27 B0 AD|0000", "2D 2024 2A 20 7D 200D 7B 29 2028 3C 2E|0100000010", "24 61 3001 31 A3 3B 24 2D A 1F1E7 2C 2764 5D0 2F 5B 9|001001001011010", "3E 2028 21 5D1 2D 21 1F1E6 31 85 D 2028 5D A 27|0110011011101", "4E00 33 1F466 2E 2060 28 1F1E7 33 20AC 61 2024 5F|11000010001", "62 2014 200D 2F 2013 5D1 2A 1100 25|10001010", "31 9 AC00 AC01 27 1161 300 AD 3C 62 62 2014|01100001001", "1F1E7 AC01 1F600 FFFC 2B 5D 27 3001 61 2E 32|1111000100", "20 7D 29 2060 3005 7B|00001", "3B 20 7D 32 5D1 1F1E7 9 200B 2010 200B 5D0 B0 63|001010010100", "1161 31 21 21 3D 22|10010", "1F466 2028 2B 2013 1100 2764 62 26 4E00 2E|010111010", "200B 3042 3042 A0 31 1F3FB 5D1|110011", "1161 D 3005 1F3FB|011", "63 3D 29 3042 20 20 29 2010 5B 32 2E A0 31 A2 2764 7B|001000010000011", "62 20AC 23 25 20 5D1 61 2D 2B 63 1100 4E00|00001001011", "AD 7B 1161 2F 5D1 1161 300 33 2D 27 2030 1F3FB|10001010001", "3005 2032 31 26 7D 2014 31 5D0 28 2010 32 5B 3005 5D1 1161 2F|100011000100110", "2C 2A 1F3FB 3F 2A 2013 2E 25 2014 1F600|010100111", "1F1E7 A 7B 21 5D1 20|01010", "2B 3005 3E A0|010", "5D 2024 5B AC01 26 31 20|010100", "2013 1F466 1F466 1F1E7|111", "2010 2D 9 63 A3 31 200D 1F3FB 2028|00100000", "21 29 200D 11A8 3042 A0 61 5D0 AC00|00010001", "2F 7E 24 200B 1F466 1F600 7B 85 A2|10011101", "3B B0 5D 2F 5B 2B AC00 2014 2013 3F 2A|1001001001", "3F 2D 3B 7B|001", "2B 61 2028 300 3005 1F466 2E 1F1E7|0010101", "1F3FB AD 2B 20 2013 33 7D 2A 5B A2 1F1E6|0101101001"]

test "random text breaks where libunibreak and ICU break it" {
  var bad = 0
  var first = ""
  for v in vectors {
    val f = split(v, "|")
    val got = gotBits(cpsOfHex(f[0]))
    if got != f[1] {
      bad = bad + 1
      if first.length == 0 {
        first = f[0] + " expected " + f[1] + " got " + got
      }
    }
  }
  assertEqual(first, "", "first disagreement")
  assertEqualInt(bad, 0, "disagreements")
}
