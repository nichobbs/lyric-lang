//! Std.Char beyond ASCII on `--target native` (#6858): classification by
//! Unicode general category and the simple case mapping, over lyric-rt's
//! generated tables. The expected values are the ones `System.Char` and
//! `java.lang.Character` give; `char_tests.l` covers ASCII on every target.
//!
//!   lyric test --target native lyric-stdlib/tests/char_native_tests.l
@test_module
package Std.Char.NativeTests

import Std.Core
import Std.Char
import Std.Testing

test "letters outside ASCII: Latin-1, Greek, Han, titlecase, modifier" {
  assertTrue(isLetter('\u{00E9}'), "e acute (Ll)")
  assertTrue(isLetter('\u{00C9}'), "E acute (Lu)")
  assertTrue(isLetter('\u{03A3}'), "Greek capital sigma (Lu)")
  assertTrue(isLetter('\u{4E2D}'), "a Han ideograph (Lo)")
  assertTrue(isLetter('\u{01C5}'), "Latin capital D with small z with caron (Lt)")
  assertTrue(isLetter('\u{02B0}'), "modifier letter small h (Lm)")
  assertTrue(not isLetter('\u{00D7}'), "multiplication sign is a symbol")
  assertTrue(not isLetter('\u{2014}'), "em dash is punctuation")
  assertTrue(not isLetter('\u{0378}'), "an unassigned code point")
  assertTrue(isLetterOrDigit('\u{00E9}'), "a non-ASCII letter is a letter or digit")
}

test "digits outside ASCII are Nd only" {
  assertTrue(isDigit('\u{0663}'), "Arabic-Indic digit three")
  assertTrue(isDigit('\u{FF15}'), "fullwidth digit five")
  assertTrue(not isDigit('\u{00BD}'), "vulgar fraction one half is No, not Nd")
  assertTrue(isLetterOrDigit('\u{0663}'), "a non-ASCII digit is a letter or digit")
}

test "upper and lower follow Lu and Ll; titlecase is neither" {
  assertTrue(isUpper('\u{00C9}') and not isLower('\u{00C9}'), "E acute")
  assertTrue(isLower('\u{00E9}') and not isUpper('\u{00E9}'), "e acute")
  assertTrue(isUpper('\u{03A3}') and isLower('\u{03C3}'), "Greek sigma pair")
  assertTrue(not isUpper('\u{01C5}') and not isLower('\u{01C5}'), "titlecase dz")
  assertTrue(not isUpper('\u{4E2D}') and not isLower('\u{4E2D}'), "a caseless letter")
}

test "punctuation and control outside ASCII" {
  assertTrue(isPunctuation('\u{00A1}'), "inverted exclamation mark (Po)")
  assertTrue(isPunctuation('\u{2014}'), "em dash (Pd)")
  assertTrue(isPunctuation('\u{00AB}'), "left guillemet (Pi)")
  assertTrue(not isPunctuation('\u{00D7}'), "multiplication sign (Sm)")
  assertTrue(isControl('\u{0085}'), "next line (C1)")
  assertTrue(isControl('\u{009F}'), "application program command (C1)")
  assertTrue(not isControl('\u{00A0}'), "no-break space")
}

test "case conversion maps accented, Greek and Cyrillic letters and leaves the rest" {
  assertTrue(toUpper('\u{00E9}') == '\u{00C9}', "e acute to E acute")
  assertTrue(toLower('\u{00C9}') == '\u{00E9}', "E acute to e acute")
  assertTrue(toUpper('\u{03C3}') == '\u{03A3}', "sigma to capital sigma")
  assertTrue(toLower('\u{0416}') == '\u{0436}', "Cyrillic zhe")
  assertTrue(toUpper('1') == '1', "a digit is unchanged")
  assertTrue(toLower('\u{4E2D}') == '\u{4E2D}', "a caseless letter is unchanged")
}
