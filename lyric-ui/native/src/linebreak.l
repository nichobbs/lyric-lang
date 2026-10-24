//! linebreak.l - Ui.Native.LineBreak: the Unicode line breaking algorithm (UAX #14) for the native
//! host's text (docs/67 G10, #8410).
//!
//! `breaksIn` gives, for the text of one paragraph, whether a line may break before each code point:
//! every rule LB2 to LB31 of Unicode 15.1, in order, over the line break classes of
//! `Ui.Native.UnicodeData` (kinsoku and the other closing and opening punctuation rules, numbers
//! with their prefixes and suffixes, quotation marks by their initial or final category, Hangul
//! syllables, regional-indicator pairs, emoji modifiers, hyphens before Hebrew letters).  There is no
//! dictionary-based breaking of Thai, Lao, Khmer and Myanmar, which UAX #14 leaves to the
//! implementation: such text breaks only at its spaces and punctuation.
//!
//! It is plain Lyric over code points, so it runs, and is tested, on every target.
@pure
package Ui.Native.LineBreak

import Std.Core
import Std.Collections
import Std.Buffer as Buf
import Ui.Native.UnicodeData

/// A break is not allowed before the code point.
pub val noBreak: Int = 0

/// A break is allowed before the code point.
pub val breakAllowed: Int = 1

/// A break is required before the code point (after a line feed, or at the end of the text).
pub val breakRequired: Int = 2

val lbAL: Int = 2

val lbBA: Int = 4

val lbBB: Int = 5

val lbBK: Int = 6

val lbCB: Int = 7

val lbCL: Int = 8

val lbCM: Int = 9

val lbCR: Int = 10

val lbEX: Int = 11

val lbGL: Int = 12

val lbHY: Int = 13

val lbID: Int = 14

val lbIN: Int = 15

val lbIS: Int = 16

val lbLF: Int = 17

val lbNS: Int = 18

val lbNU: Int = 19

val lbOP: Int = 20

val lbPO: Int = 21

val lbPR: Int = 22

val lbQU: Int = 23

val lbSA: Int = 24

val lbSP: Int = 26

val lbSY: Int = 27

val lbZW: Int = 28

val lbNL: Int = 29

val lbWJ: Int = 30

val lbH2: Int = 31

val lbH3: Int = 32

val lbJL: Int = 33

val lbJT: Int = 34

val lbJV: Int = 35

val lbCP: Int = 36

val lbCJ: Int = 37

val lbHL: Int = 38

val lbRI: Int = 39

val lbEB: Int = 40

val lbEM: Int = 41

val lbZWJ: Int = 42

val flagWide: Int = 64

val flagPictographicUnassigned: Int = 128

val flagInitialQuote: Int = 256

val flagFinalQuote: Int = 512

val flagMark: Int = 1024

// LB1: the classes whose meaning depends on the context are resolved to the ones that can be
// handled alone.
func resolvedClass(v: Int): Int {
  val c = v.and(63)
  if c == 0 or c == 1 or c == 25 {
    lbAL
  } else if c == lbSA {
    if v.and(flagMark) != 0 {
      lbCM
    } else {
      lbAL
    }
  } else if c == lbCJ {
    lbNS
  } else {
    c
  }
}

func isMandatoryClass(c: Int): Bool {
  c == lbBK or c == lbCR or c == lbLF or c == lbNL
}

func isNumberFollower(c: Int): Bool {
  c == lbNU or c == lbSY or c == lbIS
}

func isHangulOrJamo(c: Int): Bool {
  c == lbJL or c == lbJV or c == lbJT or c == lbH2 or c == lbH3
}

func isAlphabetic(c: Int): Bool {
  c == lbAL or c == lbHL
}

// Whether a break is allowed before `cps[from + i]`, which comes after `cps[from + i - 1]`.
// `eff` holds each code point's class once combining marks have joined the character before them
// (LB9, LB10), `raw` the class itself, `flags` the properties of the character a mark belongs to.
func decide(
  i: Int,
  n: Int,
  raw: buffer[Int],
  eff: buffer[Int],
  flags: buffer[Int],
  attached: buffer[Int],
  lastNonSpace: Int,
  numberState: Int,
  regionalRun: Int,
): Int {
  val a = eff[i - 1]
  val b = eff[i]
  // The class of the character after `i` that is not a mark joined to it.
  var nextIdx = i + 1
  while nextIdx < n and attached[nextIdx] == 1 {
    nextIdx = nextIdx + 1
  }
  val next = if nextIdx < n { eff[nextIdx] } else { -1 }
  val base = if lastNonSpace >= 0 { eff[lastNonSpace] } else { -1 }
  // LB4, LB5
  if a == lbBK or a == lbLF or a == lbNL {
    return breakRequired
  }
  if a == lbCR {
    return if raw[i] == lbLF { noBreak } else { breakRequired }
  }
  // LB6
  if isMandatoryClass(raw[i]) {
    return noBreak
  }
  // LB7
  if b == lbSP or b == lbZW {
    return noBreak
  }
  // LB8
  if base == lbZW {
    return breakAllowed
  }
  // LB8a
  if raw[i - 1] == lbZWJ {
    return noBreak
  }
  // LB9
  if attached[i] == 1 {
    return noBreak
  }
  // LB11
  if b == lbWJ or a == lbWJ {
    return noBreak
  }
  // LB12, LB12a
  if a == lbGL {
    return noBreak
  }
  if b == lbGL and a != lbSP and a != lbBA and a != lbHY {
    return noBreak
  }
  // LB13
  if b == lbCL or b == lbCP or b == lbEX or b == lbSY {
    return noBreak
  }
  // LB14
  if base == lbOP {
    return noBreak
  }
  // LB15a
  if base == lbQU and flags[lastNonSpace].and(flagInitialQuote) != 0 {
    val before = if lastNonSpace == 0 { lbBK } else { eff[lastNonSpace - 1] }
    if before == lbBK or before == lbCR or before == lbLF or before == lbNL or before == lbOP or before == lbQU or before == lbGL or before == lbSP or before == lbZW {
      return noBreak
    }
  }
  // LB15b
  if b == lbQU and flags[i].and(flagFinalQuote) != 0 {
    if next == -1 or next == lbSP or next == lbGL or next == lbWJ or next == lbCL or next == lbQU or next == lbCP or next == lbEX or next == lbIS or next == lbSY or next == lbBK or next == lbCR or next == lbLF or next == lbNL or next == lbZW {
      return noBreak
    }
  }
  // LB15c, LB15d
  if a == lbSP and b == lbIS and next == lbNU {
    return breakAllowed
  }
  if b == lbIS {
    return noBreak
  }
  // LB16, LB17
  if (base == lbCL or base == lbCP) and b == lbNS {
    return noBreak
  }
  if base == 3 and b == 3 {
    return noBreak
  }
  // LB18
  if a == lbSP {
    return breakAllowed
  }
  // LB19
  if b == lbQU or a == lbQU {
    return noBreak
  }
  // LB20
  if b == lbCB or a == lbCB {
    return breakAllowed
  }
  // LB21
  if b == lbBA or b == lbHY or b == lbNS or a == lbBB {
    return noBreak
  }
  // LB21a
  if a == lbHY or a == lbBA {
    var bi = i - 1
    while bi > 0 and attached[bi] == 1 {
      bi = bi - 1
    }
    if bi > 0 and eff[bi - 1] == lbHL {
      return noBreak
    }
  }
  // LB21b
  if a == lbSY and b == lbHL {
    return noBreak
  }
  // LB22
  if b == lbIN {
    return noBreak
  }
  // LB23, LB23a
  if (isAlphabetic(a) and b == lbNU) or (a == lbNU and isAlphabetic(b)) {
    return noBreak
  }
  if a == lbPR and (b == lbID or b == lbEB or b == lbEM) {
    return noBreak
  }
  if (a == lbID or a == lbEB or a == lbEM) and b == lbPO {
    return noBreak
  }
  // LB24
  if (a == lbPR or a == lbPO) and isAlphabetic(b) {
    return noBreak
  }
  if isAlphabetic(a) and (b == lbPR or b == lbPO) {
    return noBreak
  }
  // LB25
  if (a == lbCL or a == lbCP or a == lbNU) and (b == lbPO or b == lbPR) {
    return noBreak
  }
  if (a == lbPO or a == lbPR) and (b == lbOP or b == lbNU) {
    return noBreak
  }
  if (a == lbHY or a == lbIS or a == lbNU or a == lbSY) and b == lbNU {
    return noBreak
  }
  // LB26, LB27
  if a == lbJL and (b == lbJL or b == lbJV or b == lbH2 or b == lbH3) {
    return noBreak
  }
  if (a == lbJV or a == lbH2) and (b == lbJV or b == lbJT) {
    return noBreak
  }
  if (a == lbJT or a == lbH3) and b == lbJT {
    return noBreak
  }
  if isHangulOrJamo(a) and b == lbPO {
    return noBreak
  }
  if a == lbPR and isHangulOrJamo(b) {
    return noBreak
  }
  // LB28, LB29
  if isAlphabetic(a) and isAlphabetic(b) {
    return noBreak
  }
  if a == lbIS and isAlphabetic(b) {
    return noBreak
  }
  // LB30
  if (isAlphabetic(a) or a == lbNU) and b == lbOP and flags[i].and(flagWide) == 0 {
    return noBreak
  }
  if a == lbCP and flags[i - 1].and(flagWide) == 0 and (isAlphabetic(b) or b == lbNU) {
    return noBreak
  }
  // LB30a
  if a == lbRI and b == lbRI and regionalRun % 2 == 1 {
    return noBreak
  }
  // LB30b
  if b == lbEM and (a == lbEB or flags[i - 1].and(flagPictographicUnassigned) != 0) {
    return noBreak
  }
  // LB31
  breakAllowed
}

/// For each position of the text `cps[from ..< to]`, whether a line may break there.  Element `k`
/// of the result is about the position between `cps[from + k - 1]` and `cps[from + k]`: `noBreak`,
/// `breakAllowed`, or `breakRequired` (after a line feed and its kin).  Element 0 is always
/// `noBreak` (LB2) and the last, at the end of the text, `breakRequired` (LB3).
pub func breaksIn(cps: in slice[Int], from: in Int, to: in Int): List[Int] {
  val result: List[Int] = newList()
  val n = to - from
  result.add(noBreak)
  if n <= 0 {
    return result
  }
  var raw = Buf.filled(n, 0)
  var eff = Buf.filled(n, 0)
  var flags = Buf.filled(n, 0)
  var attached = Buf.filled(n, 0)
  var i = 0
  while i < n {
    val v = UnicodeData.lineBreakValueOf(cps[from + i])
    val c = resolvedClass(v)
    raw[i] = c
    flags[i] = v
    if (c == lbCM or c == lbZWJ) and i > 0 and not (isMandatoryClass(eff[i - 1]) or eff[i - 1] == lbSP or eff[i - 1] == lbZW) {
      eff[i] = eff[i - 1]
      flags[i] = flags[i - 1]
      attached[i] = 1
    } else if c == lbCM or c == lbZWJ {
      eff[i] = lbAL
    } else {
      eff[i] = c
    }
    i = i + 1
  }
  var lastNonSpace = -1
  var numberState = 0
  var regionalRun = 0
  i = 1
  while i < n {
    val p = i - 1
    if eff[p] != lbSP and attached[p] == 0 {
      lastNonSpace = p
    }
    if attached[p] == 0 {
      val e = eff[p]
      if e == lbNU {
        numberState = 1
      } else if numberState == 1 and (e == lbSY or e == lbIS) {
        numberState = 1
      } else if numberState == 1 and (e == lbCL or e == lbCP) {
        numberState = 2
      } else {
        numberState = 0
      }
      regionalRun = if e == lbRI { regionalRun + 1 } else { 0 }
    }
    result.add(decide(i, n, raw, eff, flags, attached, lastNonSpace, numberState, regionalRun))
    i = i + 1
  }
  result.add(breakRequired)
  result
}

/// True when `cps[i]` joins the character before it (a combining mark or a zero width joiner, rules
/// LB9 and LB8a): a line must not start there, even when a word is cut for lack of room.
pub func joinsPrevious(cps: in slice[Int], i: in Int): Bool {
  if i <= 0 {
    return false
  }
  val c = resolvedClass(UnicodeData.lineBreakValueOf(cps[i]))
  val before = resolvedClass(UnicodeData.lineBreakValueOf(cps[i - 1]))
  if before == lbZWJ {
    return true
  };
  (c == lbCM or c == lbZWJ) and not isMandatoryClass(before) and before != lbSP and before != lbZW
}
