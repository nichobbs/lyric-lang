//! wordbreak.l - Unicode.WordBreak: the word boundaries of Unicode Text Segmentation (UAX #29,
//! section 4), and the word movement a text editor builds on them (#8497).
//!
//! `boundariesIn` gives, for a stretch of text, whether each position between two code points is a
//! word boundary: every rule WB1 to WB999 of Unicode 16.0 over the Word_Break values of
//! `Unicode.Data` (CRLF and newlines, emoji ZWJ sequences, runs of horizontal space, the Extend,
//! Format and ZWJ characters that join the one before them, letters with their apostrophes and
//! full stops, numbers with their separators, Katakana, connectors, regional-indicator pairs).
//! All of Unicode's `WordBreakTest.txt` passes (`tests/conformance/`).  The text between two
//! boundaries is a segment; `isWordLike` tells a word (letters, digits, kana, ideographs, the
//! letters of the scripts written without spaces) from a segment of spaces or punctuation, and
//! `nextWordEnd` and `previousWordStart` are the moves of Ctrl+Right and Ctrl+Left.  Scripts written
//! without spaces between words (Thai, Lao, Khmer, Myanmar and the other Line_Break SA scripts) are
//! one segment per run of letters: as in CLDR's and ICU's root rules, an SA character that is not
//! Extend is taken as ALetter (UAX #29 gives it Other, a boundary between every two letters, and
//! leaves the words to a dictionary).  WordBreakTest.txt has no SA text, so it tests the rules
//! without this; `lyric-unicode-dict` (`Unicode.Dictionary`) adds the dictionary's boundaries.
//!
//! It is plain Lyric over code points, so it runs, and is tested, on every target.
@pure
package Unicode.WordBreak

import Std.Core
import Std.Collections
import Std.Buffer as Buf
import Unicode.Data as UnicodeData

val wbOther: Int = 0

val wbCR: Int = 1

val wbLF: Int = 2

val wbNewline: Int = 3

val wbExtend: Int = 4

val wbZWJ: Int = 5

val wbRI: Int = 6

val wbFormat: Int = 7

val wbKatakana: Int = 8

val wbHebrewLetter: Int = 9

val wbALetter: Int = 10

val wbSingleQuote: Int = 11

val wbDoubleQuote: Int = 12

val wbMidNumLet: Int = 13

val wbMidLetter: Int = 14

val wbMidNum: Int = 15

val wbNumeric: Int = 16

val wbExtendNumLet: Int = 17

val wbWSegSpace: Int = 18

val flagPictographic: Int = 32

// Line_Break values as `Unicode.Data` encodes them: indexes into the generator's `lineBreakNames`
// (`tools/generate/generate.l`), the same numbering `Unicode.LineBreak` uses.
val lbID: Int = 14

val lbSA: Int = 24

val lbH2: Int = 31

val lbH3: Int = 32

val lbJL: Int = 33

val lbJT: Int = 34

val lbJV: Int = 35

val lbCJ: Int = 37

val lbAK: Int = 43

val lbAS: Int = 45

func isIgnored(c: Int): Bool {
  c == wbExtend or c == wbFormat or c == wbZWJ
}

func isNewlineClass(c: Int): Bool {
  c == wbCR or c == wbLF or c == wbNewline
}

func isAHLetter(c: Int): Bool {
  c == wbALetter or c == wbHebrewLetter
}

func isMidNumLetQ(c: Int): Bool {
  c == wbMidNumLet or c == wbSingleQuote
}

// Whether there is a word boundary before index `i`, 0 < i < n.  `base[k]` is the character rule
// WB4 folds `k` into (an Extend, Format or ZWJ character joins the one before it, unless that is a
// newline or the start of the text; then it stands for itself), `eff[k]` that character's class,
// `after[k]` the index of the first character after `k` that WB4 does not fold, or `n`, and
// `riRun[k]` how many regional indicators end at `k`, counted back over the folded characters.
func boundaryAt(
  i: Int,
  n: Int,
  cls: buffer[Int],
  pict: buffer[Int],
  base: buffer[Int],
  eff: buffer[Int],
  after: buffer[Int],
  riRun: buffer[Int],
): Bool {
  val prevRaw = cls[i - 1]
  val curRaw = cls[i]
  // WB3, WB3a, WB3b
  if prevRaw == wbCR and curRaw == wbLF {
    return false
  }
  if isNewlineClass(prevRaw) or isNewlineClass(curRaw) {
    return true
  }
  // WB3c
  if prevRaw == wbZWJ and pict[i] == 1 {
    return false
  }
  // WB3d
  if prevRaw == wbWSegSpace and curRaw == wbWSegSpace {
    return false
  }
  // WB4
  if isIgnored(curRaw) {
    return false
  }
  val aIdx = base[i - 1]
  val a = eff[i - 1]
  val b = curRaw
  val beforeA = if aIdx > 0 { eff[aIdx - 1] } else { -1 }
  val cIdx = after[i]
  val c = if cIdx < n { eff[cIdx] } else { -1 }
  // WB5
  if isAHLetter(a) and isAHLetter(b) {
    return false
  }
  // WB6, WB7
  if isAHLetter(a) and (b == wbMidLetter or isMidNumLetQ(b)) and isAHLetter(c) {
    return false
  }
  if isAHLetter(beforeA) and (a == wbMidLetter or isMidNumLetQ(a)) and isAHLetter(b) {
    return false
  }
  // WB7a, WB7b, WB7c
  if a == wbHebrewLetter and b == wbSingleQuote {
    return false
  }
  if a == wbHebrewLetter and b == wbDoubleQuote and c == wbHebrewLetter {
    return false
  }
  if beforeA == wbHebrewLetter and a == wbDoubleQuote and b == wbHebrewLetter {
    return false
  }
  // WB8, WB9, WB10
  if (a == wbNumeric or isAHLetter(a)) and b == wbNumeric {
    return false
  }
  if a == wbNumeric and isAHLetter(b) {
    return false
  }
  // WB11, WB12
  if beforeA == wbNumeric and (a == wbMidNum or isMidNumLetQ(a)) and b == wbNumeric {
    return false
  }
  if a == wbNumeric and (b == wbMidNum or isMidNumLetQ(b)) and c == wbNumeric {
    return false
  }
  // WB13, WB13a, WB13b
  if a == wbKatakana and b == wbKatakana {
    return false
  }
  if (isAHLetter(a) or a == wbNumeric or a == wbKatakana or a == wbExtendNumLet) and b == wbExtendNumLet {
    return false
  }
  if a == wbExtendNumLet and (isAHLetter(b) or b == wbNumeric or b == wbKatakana) {
    return false
  }
  // WB15, WB16: regional indicators pair up, counted back over the characters WB4 folds away.
  if a == wbRI and b == wbRI and riRun[aIdx] % 2 == 1 {
    return false
  }
  // WB999
  true
}

/// For each position of the text `cps[from ..< to]`, whether it is a word boundary.  Element `k` of
/// the result is about the position before `cps[from + k]`; the first and the last (`to - from`)
/// are boundaries (WB1, WB2).  An empty text has one position, which is not a boundary: the result is
/// `[false]`.
pub func boundariesIn(cps: in slice[Int], from: in Int, to: in Int): List[Bool] {
  val result: List[Bool] = newList()
  val n = to - from
  if n <= 0 {
    result.add(false)
    return result
  }
  var cls = Buf.filled(n, 0)
  var pict = Buf.filled(n, 0)
  var base = Buf.filled(n, 0)
  var eff = Buf.filled(n, 0)
  var riRun = Buf.filled(n, 0)
  var i = 0
  while i < n {
    val v = UnicodeData.wordBreakValueOf(cps[from + i])
    cls[i] = v.and(31)
    if cls[i] == wbOther and UnicodeData.lineBreakValueOf(cps[from + i]).and(63) == lbSA {
      cls[i] = wbALetter
    }
    pict[i] = if v.and(flagPictographic) != 0 { 1 } else { 0 }
    if isIgnored(cls[i]) and i > 0 and not isNewlineClass(cls[base[i - 1]]) {
      base[i] = base[i - 1]
    } else {
      base[i] = i
    }
    eff[i] = cls[base[i]]
    riRun[i] = if base[i] != i {
      riRun[base[i]]
    } else if eff[i] == wbRI {
      1 + (if i > 0 { riRun[base[i - 1]] } else { 0 })
    } else {
      0
    }
    i = i + 1
  }
  // Filled from the end so the whole pass stays linear however long a run of folded characters is.
  var after = Buf.filled(n, n)
  var k = n - 2
  while k >= 0 {
    after[k] = if base[k + 1] == k + 1 { k + 1 } else { after[k + 1] }
    k = k - 1
  }
  result.add(true)
  i = 1
  while i < n {
    result.add(boundaryAt(i, n, cls, pict, base, eff, after, riRun))
    i = i + 1
  }
  result.add(true)
  result
}

/// True when the segment `cps[from ..< to]` is a word rather than spaces or punctuation: it holds a
/// letter, a digit, kana, an ideograph or a Hangul syllable, or a letter of a script written without
/// spaces.
pub func isWordLike(cps: in slice[Int], from: in Int, to: in Int): Bool {
  var i = from
  while i < to {
    val wb = UnicodeData.wordBreakValueOf(cps[i]).and(31)
    if isAHLetter(wb) or wb == wbNumeric or wb == wbKatakana or wb == wbExtendNumLet {
      return true
    }
    // Line_Break ID, Hangul and jamo, kana, SA, Aksara: words in the scripts UAX #29 gives no
    // letter value.
    val lb = UnicodeData.lineBreakValueOf(cps[i]).and(63)
    if lb == lbID or lb == lbH2 or lb == lbH3 or lb == lbJL or lb == lbJT or lb == lbJV or lb == lbCJ or lb == lbSA or lb == lbAK or lb == lbAS {
      return true
    }
    i = i + 1
  }
  false
}

/// The position Ctrl+Right moves the caret to from `position` in `cps[0 ..< n]`: the end of the
/// word it is in, or of the next word after it; the end of the text when there is none.
pub func nextWordEnd(cps: in slice[Int], position: in Int): Int {
  val n = cps.length
  if position >= n {
    return n
  }
  val p = if position < 0 { 0 } else { position }
  val bounds = boundariesIn(cps, 0, n)
  var start = p
  while start > 0 and not bounds[start] {
    start = start - 1
  }
  while start < n {
    var stop = start + 1
    while stop < n and not bounds[stop] {
      stop = stop + 1
    }
    if stop > p and isWordLike(cps, start, stop) {
      return stop
    }
    start = stop
  }
  n
}

/// The position Ctrl+Left moves the caret to from `position` in `cps[0 ..< n]`: the start of the
/// word it is in, or of the word before it; the start of the text when there is none.
pub func previousWordStart(cps: in slice[Int], position: in Int): Int {
  val n = cps.length
  if position <= 0 {
    return 0
  }
  val p = if position > n { n } else { position }
  val bounds = boundariesIn(cps, 0, n)
  var stop = p
  while stop < n and not bounds[stop] {
    stop = stop + 1
  }
  while stop > 0 {
    var start = stop - 1
    while start > 0 and not bounds[start] {
      start = start - 1
    }
    if start < p and isWordLike(cps, start, stop) {
      return start
    }
    stop = start
  }
  0
}
