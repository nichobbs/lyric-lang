@test_module
package Unicode.DictionaryTests

import Std.Core
import Std.Collections
import Std.String
import Std.Testing
import Unicode.LineBreak
import Unicode.Dictionary

// The positions of the line break opportunities of `s` (0 and the end included), as ICU lists them.
func lineStops(s: String): String {
  val cps = codePoints(s)
  val bs = Dictionary.lineBreaksIn(cps, 0, cps.length)
  var r = "0"
  var k = 1
  while k <= cps.length {
    if bs[k] != LineBreak.noBreak {
      r = r + " " + k.toString()
    }
    k = k + 1
  }
  r
}

// The positions of the word boundaries of `s`.
func wordStops(s: String): String {
  val cps = codePoints(s)
  val bs = Dictionary.wordBoundariesIn(cps, 0, cps.length)
  var r = "0"
  var k = 1
  while k <= cps.length {
    if bs[k] {
      r = r + " " + k.toString()
    }
    k = k + 1
  }
  r
}

test "a run of each script is divided into its words" {
  assertEqual(wordStops("ภาษาไทยง่ายนิดเดียว"), "0 4 7 11 14 19", "Thai")
  assertEqual(wordStops("ພາສາລາວງ່າຍດາຍ"), "0 4 7 14", "Lao")
  assertEqual(wordStops("ភាសាខ្មែរងាយស្រួល"), "0 9 17", "Khmer")
  assertEqual(wordStops("မြန်မာဘာသာစကား"), "0 10 14", "Myanmar")
}

test "line breaks inside a run are the same as its word boundaries" {
  assertEqual(lineStops("ภาษาไทยง่ายนิดเดียว"), "0 4 7 11 14 19", "Thai")
  assertEqual(lineStops("မြန်မာဘာသာစကား"), "0 10 14", "Myanmar")
}

test "Thai MAIYAMOK and PAIYANNOI stay with the word before them" {
  assertEqual(wordStops("ไปๆมาๆ"), "0 3 6", "MAIYAMOK")
  assertEqual(wordStops("กรุงเทพฯ มหานคร"), "0 8 9 15", "PAIYANNOI, as words")
  assertEqual(lineStops("กรุงเทพฯ มหานคร"), "0 9 15", "PAIYANNOI, as lines")
}

test "the rules decide everything outside the runs" {
  assertEqual(wordStops("ไทย 2024 ลาว"), "0 3 4 8 9 12", "digits and spaces as words")
  assertEqual(lineStops("ไทย 2024 ลาว"), "0 4 9 12", "digits and spaces as lines")
  assertEqual(wordStops("abc ภาษาไทย def"), "0 3 4 8 11 12 15", "Latin around Thai")
}

test "text the dictionaries do not handle is left as the rules leave it" {
  assertEqual(wordStops("hello world"), "0 5 6 11", "Latin")
  assertTrue(Dictionary.handles(0x0E01), "Thai is handled")
  assertFalse(Dictionary.handles(0x1A20), "Tai Tham is not")
  assertFalse(Dictionary.handles(0x0E50), "Thai digits are not SA")
  val none: slice[Int] = []
  assertEqualInt(Dictionary.dictionaryBreaksIn(none, 0, 0).count, 0, "empty text")
}

test "a run shorter than two words has no break inside" {
  assertEqual(wordStops("ไทย"), "0 3", "one Thai word")
  assertEqual(wordStops("ກາ"), "0 2", "one short Lao word")
}
