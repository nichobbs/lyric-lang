//! dictionary.l - Unicode.Dictionary: word segmentation by dictionary for the scripts written without
//! spaces between words, Thai, Lao, Khmer and Myanmar (#8497, D414).
//!
//! UAX #14 and UAX #29 leave a run of these scripts (Line_Break SA) whole and hand it to a dictionary;
//! `Unicode.LineBreak` and `Unicode.WordBreak` do the first half.  This package does the second, as
//! ICU 74.2 does it: the dictionary break engines of ICU's `dictbe.cpp` (maximal matching over its
//! word lists, three words of look-ahead, resynchronisation over unknown text, never a break before a
//! combining mark, and Thai's PAIYANNOI and MAIYAMOK suffixes), run over each run of one of the four
//! scripts inside a segment the rules left whole, as ICU's `DictionaryCache` runs them.  The word
//! lists are ICU's own (`Unicode.Dictionary.Data`).  `lineBreaksIn` and `wordBoundariesIn` give the
//! rule-based results with the dictionary's breaks added; `tests/conformance` checks them against
//! ICU 74.2's line and word break iterators.  Runs of other SA scripts (Tai Tham, New Tai Lue, Tai
//! Viet and the rest) stay whole, as in ICU, which has no dictionary for them.
//!
//! It is plain Lyric over code points, so it runs, and is tested, on every target.
@pure
package Unicode.Dictionary

import Std.Core
import Std.Collections
import Std.String
import Std.Buffer as Buf
import Unicode.Data as UnicodeData
import Unicode.LineBreak
import Unicode.WordBreak
import Unicode.Dictionary.Data as Words

val noEngine: Int = -1

val thai: Int = 0

val lao: Int = 1

val khmer: Int = 2

val myanmar: Int = 3

val lbSA: Int = 24

val flagMark: Int = 1024

val paiyannoi: Int = 0x0E2F

val maiyamok: Int = 0x0E46

// The constants of ICU's engines, the same for the four scripts.
val lookahead: Int = 3

val rootCombineThreshold: Int = 3

val prefixCombineThreshold: Int = 3

val minWordSpan: Int = 4

// ICU's POSSIBLE_WORD_LIST_MAX: the most candidates kept at one position.
val maxCandidates: Int = 20

// The state of the engine in one buffer: three PossibleWord slots of `slotSize` values each (offset,
// count, longest prefix, current, mark, then the candidate lengths), then the text position.
val slotSize: Int = 25

val stPos: Int = 75

// A word's position in a word list: its chunk times `chunkStride`, plus its offset in the chunk.  The
// generator cuts chunks far shorter than this.
val chunkStride: Int = 1048576

val stSize: Int = 76

func isSA(cp: Int): Bool {
  UnicodeData.lineBreakValueOf(cp).and(63) == lbSA
}

// The engine for `cp`: its script's, when it is Line_Break SA and of one of the four scripts.
func engineOf(cp: Int): Int {
  if not isSA(cp) {
    return noEngine
  }
  if cp >= 0x0E00 and cp <= 0x0E7F {
    thai
  } else if cp >= 0x0E80 and cp <= 0x0EFF {
    lao
  } else if (cp >= 0x1780 and cp <= 0x17FF) or (cp >= 0x19E0 and cp <= 0x19FF) {
    khmer
  } else if (cp >= 0x1000 and cp <= 0x109F) or (cp >= 0xA9E0 and cp <= 0xA9FF) or (cp >= 0xAA60 and cp <= 0xAA7F) {
    myanmar
  } else {
    noEngine
  }
}

/// True when `cp` is in a script this package segments (Line_Break SA in Thai, Lao, Khmer or Myanmar).
pub func handles(cp: in Int): Bool {
  engineOf(cp) != noEngine
}

// ICU's fMarkSet: the script's SA combining marks, and the space.
func isMarkOf(engine: Int, cp: Int): Bool {
  cp == 32 or (engineOf(cp) == engine and UnicodeData.lineBreakValueOf(cp).and(flagMark) != 0)
}

// ICU's fEndWordSet: the characters a word may end with.
func endsWord(engine: Int, cp: Int): Bool {
  if engineOf(cp) != engine {
    return false
  }
  if engine == thai {
    cp != 0x0E31 and not (cp >= 0x0E40 and cp <= 0x0E44)
  } else if engine == lao {
    not (cp >= 0x0EC0 and cp <= 0x0EC4)
  } else if engine == khmer {
    cp != 0x17D2
  } else {
    true
  }
}

// ICU's fBeginWordSet: the characters a word may start with.
func beginsWord(engine: Int, cp: Int): Bool {
  if engine == thai {
    (cp >= 0x0E01 and cp <= 0x0E2E) or (cp >= 0x0E40 and cp <= 0x0E44)
  } else if engine == lao {
    (cp >= 0x0E81 and cp <= 0x0EAE) or (cp >= 0x0EDC and cp <= 0x0EDD) or (cp >= 0x0EC0 and cp <= 0x0EC4)
  } else if engine == khmer {
    cp >= 0x1780 and cp <= 0x17B3
  } else {
    cp >= 0x1000 and cp <= 0x102A
  }
}

func alphabetOf(engine: Int): String {
  if engine == thai {
    Words.thaiAlphabet
  } else if engine == lao {
    Words.laoAlphabet
  } else if engine == khmer {
    Words.khmerAlphabet
  } else {
    Words.myanmarAlphabet
  }
}

func longestWordOf(engine: Int): Int {
  if engine == thai {
    Words.thaiLongestWord
  } else if engine == lao {
    Words.laoLongestWord
  } else if engine == khmer {
    Words.khmerLongestWord
  } else {
    Words.myanmarLongestWord
  }
}

func wordsOf(engine: Int): slice[String] {
  if engine == thai {
    Words.thaiWords
  } else if engine == lao {
    Words.laoWords
  } else if engine == khmer {
    Words.khmerWords
  } else {
    Words.myanmarWords
  }
}

// The ASCII character standing for the code point of rank `rank` in an alphabet (see
// `Unicode.Dictionary.Data`).
func alphabetChar(rank: Int): Int {
  var c = 33 + rank
  if c >= 34 {
    c = c + 1
  }
  if c >= 92 {
    c = c + 1
  }
  c
}

func hexAt(s: String, at: Int): Int {
  var v = 0
  var i = 0
  while i < 4 {
    val c = codeUnitAt(s, at + i)
    v = v * 16 + (if c >= 65 { c - 55 } else { c - 48 })
    i = i + 1
  }
  v
}

// The character `cp` is written as in the word lists of `alphabet`, or -1 when no word holds it.
func encode(alphabet: String, cp: Int): Int {
  var lo = 0
  var hi = alphabet.length / 4 - 1
  while lo <= hi {
    val mid = (lo + hi) / 2
    val v = hexAt(alphabet, mid * 4)
    if v == cp {
      return alphabetChar(mid)
    }
    if v < cp {
      lo = mid + 1
    } else {
      hi = mid - 1
    }
  }
  -1
}

// The end of the word starting at `i` in a chunk of a word list (the index of the space after it).
func wordEnd(s: String, i: Int): Int {
  var j = i
  while codeUnitAt(s, j) != 32 {
    j = j + 1
  }
  j
}

// The word starting at `i` in `s` against `key[0 ..< n]`: negative, zero or positive.
func compareWord(s: String, i: Int, key: buffer[Int], n: Int): Int {
  var k = 0
  while true {
    val c = codeUnitAt(s, i + k)
    if c == 32 {
      return if k == n { 0 } else { -1 }
    }
    if k == n {
      return 1
    }
    if c != key[k] {
      return c - key[k]
    }
    k = k + 1
  }
  0
}

// Whether the word starting at `i` in `s` starts with `key[0 ..< n]`.
func startsWith(s: String, i: Int, key: buffer[Int], n: Int): Bool {
  var k = 0
  while k < n {
    if codeUnitAt(s, i + k) != key[k] {
      return false
    }
    k = k + 1
  }
  true
}

// The first word of `words` not before `key[0 ..< n]`, as chunk index times 2^20 plus its offset in
// the chunk, or -1 when every word is before it.
func lowerBound(words: slice[String], key: buffer[Int], n: Int): Int {
  var lo = 0
  var hi = words.length
  while lo < hi {
    val mid = (lo + hi) / 2
    if compareWord(words[mid], 0, key, n) <= 0 {
      lo = mid + 1
    } else {
      hi = mid
    }
  }
  val c = if lo > 0 { lo - 1 } else { 0 }
  val s = words[c]
  var a = 0
  var b = s.length
  while a < b {
    val mid = (a + b) / 2
    var ws = mid
    while ws > 0 and codeUnitAt(s, ws - 1) != 32 {
      ws = ws - 1
    }
    val we = wordEnd(s, ws)
    if compareWord(s, ws, key, n) < 0 {
      a = we + 1
    } else {
      b = ws
    }
  }
  if a < s.length {
    return c * chunkStride + a
  }
  if c + 1 < words.length {
    (c + 1) * chunkStride
  } else {
    -1
  }
}

// The word after the one at `at` (as `lowerBound` gives it), or -1.
func nextWord(words: slice[String], at: Int): Int {
  val c = at / chunkStride
  val s = words[c]
  val after = wordEnd(s, at % chunkStride) + 1
  if after < s.length {
    c * chunkStride + after
  } else if c + 1 < words.length {
    (c + 1) * chunkStride
  } else {
    -1
  }
}

// ICU's DictionaryMatcher.matches for the dictionary of `engine` at `start`: the lengths of the words
// the text there starts with, shortest first (at most `maxCandidates`, read into slot `slot` of
// `st`), and how many characters were read before the dictionary had no word left.  At most
// `maxLength` characters are read, and none at or after `textEnd`.
func matches(
  st: inout buffer[Int], slot: Int, cps: slice[Int], start: Int, maxLength: Int, textEnd: Int, engine: Int
): Unit {
  val base = slot * slotSize
  val words = wordsOf(engine)
  val alphabet = alphabetOf(engine)
  // No prefix longer than the longest word matches, so at most one character more is read.
  val keyLength = if maxLength < longestWordOf(engine) + 1 { maxLength } else { longestWordOf(engine) + 1 }
  var key = Buf.filled(keyLength + 1, 0)
  var count = 0
  var matched = 0
  var at = start
  while at < textEnd {
    val cp = cps[at]
    at = at + 1
    matched = matched + 1
    val c = encode(alphabet, cp)
    if c < 0 {
      // No word holds the character: the trie has no match.
      st[base + 1] = count
      st[base + 2] = matched
      return
    }
    key[matched - 1] = c
    val lb = lowerBound(words, key, matched)
    if lb < 0 or not startsWith(words[lb / chunkStride], lb % chunkStride, key, matched) {
      st[base + 1] = count
      st[base + 2] = matched
      return
    }
    val s = words[lb / chunkStride]
    val isWord = wordEnd(s, lb % chunkStride) - lb % chunkStride == matched
    if isWord {
      if count < maxCandidates {
        st[base + 5 + count] = matched
        count = count + 1
      }
      val nx = nextWord(words, lb)
      if nx < 0 or not startsWith(words[nx / chunkStride], nx % chunkStride, key, matched) {
        // A final value: no longer word starts with this one.
        st[base + 1] = count
        st[base + 2] = matched
        return
      }
    }
    if matched >= maxLength {
      st[base + 1] = count
      st[base + 2] = matched
      return
    }
  }
  st[base + 1] = count
  st[base + 2] = matched
}

// PossibleWord::candidates: fill slot `slot` at the current position unless it is filled there
// already, move after its longest candidate and return how many there are.
func candidates(st: inout buffer[Int], slot: Int, cps: slice[Int], rangeEnd: Int, textEnd: Int, engine: Int): Int {
  val base = slot * slotSize
  val start = st[stPos]
  if start != st[base] {
    st[base] = start
    matches(st, slot, cps, start, rangeEnd - start, textEnd, engine)
  }
  val count = st[base + 1]
  if count > 0 {
    st[stPos] = start + st[base + 5 + count - 1]
  }
  st[base + 3] = count - 1
  st[base + 4] = count - 1
  count
}

// PossibleWord::acceptMarked.
func acceptMarked(st: inout buffer[Int], slot: Int): Int {
  val base = slot * slotSize
  val length = st[base + 5 + st[base + 4]]
  st[stPos] = st[base] + length
  length
}

// PossibleWord::backUp.
func backUp(st: inout buffer[Int], slot: Int): Bool {
  val base = slot * slotSize
  if st[base + 3] > 0 {
    st[base + 3] = st[base + 3] - 1
    st[stPos] = st[base] + st[base + 5 + st[base + 3]]
    return true
  }
  false
}

// PossibleWord::markCurrent.
func markCurrent(st: inout buffer[Int], slot: Int): Unit {
  val base = slot * slotSize
  st[base + 4] = st[base + 3]
}

func charAt(cps: slice[Int], at: Int, textEnd: Int): Int {
  if at < textEnd {
    cps[at]
  } else {
    -1
  }
}

// The breaks the engine of `engine` finds inside `cps[rangeStart ..< rangeEnd]`, a run of its script
// (ICU's divideUpDictionaryRange), added to `breaks`.  `textEnd` is the end of the text.
func divideRange(cps: slice[Int], rangeStart: Int, rangeEnd: Int, textEnd: Int, engine: Int, breaks: List[Int]): Unit {
  // Thai wants more than two minimal words' worth of text; the others at least that much.
  if engine == thai {
    if rangeEnd - rangeStart <= minWordSpan {
      return
    }
  } else if rangeEnd - rangeStart < minWordSpan {
    return
  }
  var st = Buf.filled(stSize, 0)
  var s = 0
  while s < lookahead {
    st[s * slotSize] = -1
    s = s + 1
  }
  st[stPos] = rangeStart
  var wordsFound = 0
  var current = rangeStart
  while st[stPos] < rangeEnd {
    current = st[stPos]
    var cuWordLength = 0
    var cpWordLength = 0
    val slot = wordsFound % lookahead
    val found = candidates(st, slot, cps, rangeEnd, textEnd, engine)
    if found == 1 {
      cuWordLength = acceptMarked(st, slot)
      cpWordLength = cuWordLength
      wordsFound = wordsFound + 1
    } else if found > 1 {
      // Of several candidates, take the one that leads on to the most words (up to three).
      var done = st[stPos] >= rangeEnd
      var more = not done
      while more {
        if candidates(st, (wordsFound + 1) % lookahead, cps, rangeEnd, textEnd, engine) > 0 {
          markCurrent(st, slot)
          if st[stPos] >= rangeEnd {
            done = true
          } else {
            var inner = true
            while inner {
              if candidates(st, (wordsFound + 2) % lookahead, cps, rangeEnd, textEnd, engine) > 0 {
                markCurrent(st, slot)
                done = true
                inner = false
              } else {
                inner = backUp(st, (wordsFound + 1) % lookahead)
              }
            }
          }
        }
        more = not done and backUp(st, slot)
      }
      cuWordLength = acceptMarked(st, slot)
      cpWordLength = cuWordLength
      wordsFound = wordsFound + 1
    }
    // A short word followed by text that is no dictionary word: join that text to it, up to where a
    // word plausibly starts.
    var uc = 0
    if st[stPos] < rangeEnd and cpWordLength < rootCombineThreshold {
      val next = wordsFound % lookahead
      if candidates(st, next, cps, rangeEnd, textEnd, engine) <= 0 and (cuWordLength == 0 or st[next * slotSize + 2] < prefixCombineThreshold) {
        var remaining = rangeEnd - (current + cuWordLength)
        var chars = 0
        while true {
          val pcIndex = st[stPos]
          val pc = charAt(cps, pcIndex, textEnd)
          if pc >= 0 {
            st[stPos] = pcIndex + 1
          }
          val pcSize = st[stPos] - pcIndex
          chars = chars + pcSize
          remaining = remaining - pcSize
          if remaining <= 0 or pcSize == 0 {
            break
          }
          uc = charAt(cps, st[stPos], textEnd)
          if endsWord(engine, pc) and beginsWord(engine, uc) {
            val n = candidates(st, (wordsFound + 1) % lookahead, cps, rangeEnd, textEnd, engine)
            st[stPos] = current + cuWordLength + chars
            if n > 0 {
              break
            }
          }
        }
        if cuWordLength <= 0 {
          wordsFound = wordsFound + 1
        }
        cuWordLength = cuWordLength + chars
      } else {
        st[stPos] = current + cuWordLength
      }
    }
    // Never stop before a combining mark.
    while st[stPos] < rangeEnd and isMarkOf(engine, charAt(cps, st[stPos], textEnd)) {
      st[stPos] = st[stPos] + 1
      cuWordLength = cuWordLength + 1
    }
    // Thai: PAIYANNOI and MAIYAMOK after a word belong to it, unless a dictionary word follows.
    if engine == thai and st[stPos] < rangeEnd and cuWordLength > 0 {
      val next = wordsFound % lookahead
      var suffix = false
      if candidates(st, next, cps, rangeEnd, textEnd, engine) <= 0 {
        uc = charAt(cps, st[stPos], textEnd)
        suffix = uc == paiyannoi or uc == maiyamok
      }
      if suffix {
        if uc == paiyannoi {
          val before = cps[st[stPos] - 1]
          if before != paiyannoi and before != maiyamok {
            st[stPos] = st[stPos] + 1
            cuWordLength = cuWordLength + 1
            uc = charAt(cps, st[stPos], textEnd)
          }
        }
        if uc == maiyamok {
          if cps[st[stPos] - 1] != maiyamok {
            st[stPos] = st[stPos] + 1
            cuWordLength = cuWordLength + 1
          }
        }
      } else {
        st[stPos] = current + cuWordLength
      }
    }
    if cuWordLength > 0 {
      breaks.add(current + cuWordLength)
    }
  }
  // No break at the end of the range: the rules decide that one.
  if breaks.count > 0 and breaks[breaks.count - 1] >= rangeEnd {
    breaks.removeAt(breaks.count - 1)
  }
}

/// The positions strictly inside `cps[from ..< to]`, a segment the line or word rules left whole,
/// where the dictionaries break it: each run of Thai, Lao, Khmer or Myanmar in it is divided into
/// words (ICU's DictionaryCache over one segment).  Positions are indexes into `cps`, ascending.
pub func dictionaryBreaksIn(cps: in slice[Int], from: in Int, to: in Int): List[Int] {
  val breaks: List[Int] = newList()
  var pos = from
  while pos < to {
    while pos < to and not isSA(cps[pos]) {
      pos = pos + 1
    }
    if pos >= to {
      break
    }
    val engine = engineOf(cps[pos])
    var runEnd = pos
    if engine == noEngine {
      // An SA script without a dictionary: ICU leaves its run whole.
      while runEnd < to and isSA(cps[runEnd]) and engineOf(cps[runEnd]) == noEngine {
        runEnd = runEnd + 1
      }
    } else {
      while runEnd < to and engineOf(cps[runEnd]) == engine {
        runEnd = runEnd + 1
      }
      divideRange(cps, pos, runEnd, to, engine, breaks)
    }
    pos = runEnd
  }
  breaks
}

/// `Unicode.LineBreak.breaksIn` with the breaks the dictionaries find inside runs of Thai, Lao, Khmer
/// and Myanmar added as `breakAllowed`.
pub func lineBreaksIn(cps: in slice[Int], from: in Int, to: in Int): List[Int] {
  val rules = LineBreak.breaksIn(cps, from, to)
  var start = from
  var k = 1
  while k <= to - from {
    if rules[k] != LineBreak.noBreak {
      for b in dictionaryBreaksIn(cps, start, from + k) {
        rules[b - from] = LineBreak.breakAllowed
      }
      start = from + k
    }
    k = k + 1
  }
  rules
}

/// `Unicode.WordBreak.boundariesIn` with the boundaries the dictionaries find inside runs of Thai,
/// Lao, Khmer and Myanmar added.
pub func wordBoundariesIn(cps: in slice[Int], from: in Int, to: in Int): List[Bool] {
  val rules = WordBreak.boundariesIn(cps, from, to)
  var start = from
  var k = 1
  while k <= to - from {
    if rules[k] {
      for b in dictionaryBreaksIn(cps, start, from + k) {
        rules[b - from] = true
      }
      start = from + k
    }
    k = k + 1
  }
  rules
}
