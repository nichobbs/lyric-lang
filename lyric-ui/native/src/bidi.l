//! bidi.l - Ui.Native.Bidi: the Unicode Bidirectional Algorithm (UAX #9) for the native host's text
//! (docs/67 G10, #8410).
//!
//! Text is analysed one paragraph at a time, in code points, like the caret: `paragraphLevelOf`
//! picks the paragraph direction from its first strong character (rules P2 and P3), `resolveLevels`
//! gives every code point its embedding level (rules X1 to X10, W1 to W7, N0 to N2, I1 and I2: explicit
//! embeddings, overrides and isolates, weak and neutral types, paired brackets), and `lineRuns` takes
//! one line of the paragraph to its runs in visual order (rules L1 and L2).  Mirroring (rule L4) is
//! `UnicodeData.mirrorOf`, applied by whoever draws a right-to-left run.
//!
//! The properties come from `Ui.Native.UnicodeData`, and the whole algorithm is checked against
//! FriBidi on generated text by the vectors in the tests.  It is plain Lyric over code points, so
//! it runs, and is tested, on every target, and the host-free text layout in `Ui.Native.Wrap`
//! builds on it.
@pure
package Ui.Native.Bidi

import Std.Core
import Std.Collections
import Std.Buffer as Buf
import Ui.Native.UnicodeData

/// A stretch `from ..< to` of code points (indices into the text analysed) of one embedding level;
/// an odd level is drawn right to left.
pub record BidiRun {
  from: Int
  to: Int
  level: Int
}

val classL: Int = 0

val classR: Int = 1

val classEN: Int = 2

val classES: Int = 3

val classET: Int = 4

val classAN: Int = 5

val classCS: Int = 6

val classB: Int = 7

val classS: Int = 8

val classWS: Int = 9

val classON: Int = 10

val classLRE: Int = 11

val classLRO: Int = 12

val classAL: Int = 13

val classRLE: Int = 14

val classRLO: Int = 15

val classPDF: Int = 16

val classNSM: Int = 17

val classBN: Int = 18

val classFSI: Int = 19

val classLRI: Int = 20

val classRLI: Int = 21

val classPDI: Int = 22

val maxDepth: Int = 125

val maxBracketDepth: Int = 63

func isIsolateInitiator(t: Int): Bool {
  t == classLRI or t == classRLI or t == classFSI
}

func isRemovedByX9(t: Int): Bool {
  t == classLRE or t == classRLE or t == classLRO or t == classRLO or t == classPDF or t == classBN
}

func isExplicitControl(t: Int): Bool {
  isRemovedByX9(t) and t != classBN or isIsolateInitiator(t) or t == classPDI
}

func isNeutralOrIsolate(t: Int): Bool {
  t == classB or t == classS or t == classWS or t == classON or t == classFSI or t == classLRI or t == classRLI or
    t == classPDI
}

func nextOdd(level: Int): Int {
  if level % 2 == 0 {
    level + 1
  } else {
    level + 2
  }
}

func nextEven(level: Int): Int {
  if level % 2 == 0 {
    level + 2
  } else {
    level + 1
  }
}

// The direction a type counts as for the neutral rules: 0 for L, 1 for R, EN and AN, -1 for none.
func strongDirection(t: Int): Int {
  if t == classL {
    0
  } else if t == classR or t == classEN or t == classAN {
    1
  } else {
    -1
  }
}

/// True when the code points `from ..< to` need the algorithm at all: when one of them is right to
/// left (Hebrew, Arabic and the like), an Arabic digit, or an explicit direction control.  Every
/// code point below U+0590 is none of these, so most text is answered without a table look-up.
pub func needsBidi(cps: in slice[Int], from: in Int, to: in Int): Bool {
  var i = from
  while i < to {
    if cps[i] >= 1424 {
      val t = UnicodeData.bidiClassOf(cps[i])
      if t == classR or t == classAL or t == classAN or isExplicitControl(t) {
        return true
      }
    }
    i = i + 1
  }
  false
}

/// The base direction of the paragraph `from ..< to` (rules P2 and P3): 1 when its first strong
/// character, not counting text inside an isolate, is right to left, else 0.
pub func paragraphLevelOf(cps: in slice[Int], from: in Int, to: in Int): Int {
  var depth = 0
  var i = from
  while i < to {
    val t = UnicodeData.bidiClassOf(cps[i])
    if isIsolateInitiator(t) {
      depth = depth + 1
    } else if t == classPDI {
      if depth > 0 {
        depth = depth - 1
      }
    } else if depth == 0 {
      if t == classL {
        return 0
      }
      if t == classR or t == classAL {
        return 1
      }
    }
    i = i + 1
  }
  0
}

// The strong type to the left of position `k` in a resolved sequence: L or R (EN and AN count as
// R), or `sos` when there is none.
func strongBefore(tt: in buffer[Int], k: in Int, sos: in Int): Int {
  var j = k - 1
  while j >= 0 {
    val d = strongDirection(tt[j])
    if d >= 0 {
      return d
    }
    j = j - 1
  }
  sos
}

func canonicalBracket(cp: Int): Int {
  if cp == 9001 {
    12296
  } else if cp == 9002 {
    12297
  } else {
    cp
  }
}

record BracketPair {
  opening: Int
  closing: Int
}

// The paired brackets of a sequence (BD16), sorted by the position of the opening one.
func bracketPairs(cps: slice[Int], from: Int, seq: List[Int], tt: buffer[Int]): List[BracketPair] {
  val pairs: List[BracketPair] = newList()
  val stackBracket: List[Int] = newList()
  val stackPos: List[Int] = newList()
  var k = 0
  var stopped = false
  while k < seq.count and not stopped {
    val cp = cps[from + seq[k]]
    val bt = if tt[k] == classON { UnicodeData.bracketTypeOf(cp) } else { 0 }
    if bt == 1 {
      if stackBracket.count >= maxBracketDepth {
        stopped = true
      } else {
        stackBracket.add(canonicalBracket(UnicodeData.pairedBracketOf(cp)))
        stackPos.add(k)
      }
    } else if bt == 2 {
      val want = canonicalBracket(cp)
      var p = stackBracket.count - 1
      var found = -1
      while p >= 0 and found < 0 {
        if stackBracket[p] == want {
          found = p
        }
        p = p - 1
      }
      if found >= 0 {
        pairs.add(BracketPair(opening = stackPos[found], closing = k))
        while stackBracket.count > found {
          stackBracket.removeAt(stackBracket.count - 1)
          stackPos.removeAt(stackPos.count - 1)
        }
      }
    }
    k = k + 1
  }
  val sorted: List[BracketPair] = newList()
  for pair in pairs {
    var at = sorted.count
    while at > 0 and sorted[at - 1].opening > pair.opening {
      at = at - 1
    }
    sorted.add(at, pair)
  }
  sorted
}

// Rule N0 on one isolating run sequence: a bracket pair takes the embedding direction when text
// inside it has that direction, else the opposite one when the text before the pair has it too.
func resolveBrackets(
  cps: slice[Int],
  from: Int,
  seq: List[Int],
  tt: inout buffer[Int],
  orig: buffer[Int],
  level: Int,
  sos: Int,
): Unit {
  val pairs = bracketPairs(cps, from, seq, tt)
  val e = level % 2
  for pair in pairs {
    var foundE = false
    var foundOpp = false
    var k = pair.opening + 1
    while k < pair.closing {
      val d = strongDirection(tt[k])
      if d == e {
        foundE = true
      } else if d >= 0 {
        foundOpp = true
      }
      k = k + 1
    }
    var dir = -1
    if foundE {
      dir = e
    } else if foundOpp {
      dir = if strongBefore(tt, pair.opening, sos) != e { 1 - e } else { e }
    }
    if dir >= 0 {
      val ty = if dir == 1 { classR } else { classL }
      tt[pair.opening] = ty
      tt[pair.closing] = ty
      var a = pair.opening + 1
      while a < seq.count and orig[seq[a]] == classNSM {
        tt[a] = ty
        a = a + 1
      }
      var c = pair.closing + 1
      while c < seq.count and orig[seq[c]] == classNSM {
        tt[c] = ty
        c = c + 1
      }
    }
  }
}

// Rules W1 to W7, N0, N1, N2, I1 and I2 on one isolating run sequence `seq` (the indices of its
// characters in the paragraph), writing each character's resolved level to `res`.
func resolveSequence(
  cps: slice[Int],
  from: Int,
  seq: List[Int],
  types: buffer[Int],
  orig: buffer[Int],
  level: Int,
  sos: Int,
  eos: Int,
  res: inout buffer[Int],
): Unit {
  val s = seq.count
  var tt = Buf.filled(s, 0)
  var k = 0
  while k < s {
    tt[k] = types[seq[k]]
    k = k + 1
  }
  val sosType = if sos == 1 { classR } else { classL }
  // W1
  k = 0
  while k < s {
    if tt[k] == classNSM {
      if k == 0 {
        tt[k] = sosType
      } else {
        val p = tt[k - 1]
        tt[k] = if isIsolateInitiator(p) or p == classPDI { classON } else { p }
      }
    }
    k = k + 1
  }
  // W2
  k = 0
  while k < s {
    if tt[k] == classEN {
      var j = k - 1
      var strong = sosType
      var searching = true
      while j >= 0 and searching {
        val t = tt[j]
        if t == classL or t == classR or t == classAL {
          strong = t
          searching = false
        }
        j = j - 1
      }
      if strong == classAL {
        tt[k] = classAN
      }
    }
    k = k + 1
  }
  // W3
  k = 0
  while k < s {
    if tt[k] == classAL {
      tt[k] = classR
    }
    k = k + 1
  }
  // W4
  k = 1
  while k < s - 1 {
    val t = tt[k]
    if t == classES and tt[k - 1] == classEN and tt[k + 1] == classEN {
      tt[k] = classEN
    } else if t == classCS {
      if tt[k - 1] == classEN and tt[k + 1] == classEN {
        tt[k] = classEN
      } else if tt[k - 1] == classAN and tt[k + 1] == classAN {
        tt[k] = classAN
      }
    }
    k = k + 1
  }
  // W5
  k = 0
  while k < s {
    if tt[k] == classET {
      var stop = k
      while stop < s and tt[stop] == classET {
        stop = stop + 1
      }
      val touches = (k > 0 and tt[k - 1] == classEN) or (stop < s and tt[stop] == classEN)
      if touches {
        var j = k
        while j < stop {
          tt[j] = classEN
          j = j + 1
        }
      }
      k = stop
    } else {
      k = k + 1
    }
  }
  // W6
  k = 0
  while k < s {
    val t = tt[k]
    if t == classES or t == classET or t == classCS {
      tt[k] = classON
    }
    k = k + 1
  }
  // W7
  k = 0
  while k < s {
    if tt[k] == classEN {
      if strongDirectionBeforeIsL(tt, k, sos) {
        tt[k] = classL
      }
    }
    k = k + 1
  }
  resolveBrackets(cps, from, seq, tt, orig, level, sos)
  // N1 and N2
  val e = level % 2
  k = 0
  while k < s {
    if isNeutralOrIsolate(tt[k]) {
      var z = k
      while z < s and isNeutralOrIsolate(tt[z]) {
        z = z + 1
      }
      val before = if k == 0 { sos } else { strongDirection(tt[k - 1]) }
      val after = if z == s { eos } else { strongDirection(tt[z]) }
      val dir = if before == after and before >= 0 { before } else { e }
      var j = k
      while j < z {
        tt[j] = if dir == 1 { classR } else { classL }
        j = j + 1
      }
      k = z
    } else {
      k = k + 1
    }
  }
  // I1 and I2
  k = 0
  while k < s {
    val t = tt[k]
    var l = level
    if level % 2 == 0 {
      if t == classR {
        l = level + 1
      } else if t == classAN or t == classEN {
        l = level + 2
      }
    } else if t == classL or t == classEN or t == classAN {
      l = level + 1
    }
    res[seq[k]] = l
    k = k + 1
  }
}

// W7 looks for the first strong L or R before an EN, not counting EN and AN as R.
func strongDirectionBeforeIsL(tt: buffer[Int], k: Int, sos: Int): Bool {
  var j = k - 1
  while j >= 0 {
    if tt[j] == classL {
      return true
    }
    if tt[j] == classR {
      return false
    }
    j = j - 1
  }
  sos == 0
}

/// The embedding level of each code point of the paragraph `from ..< to` (index `i` of the result
/// is the code point at `from + i`) under the base level `paraLevel`.
pub func resolveLevels(cps: in slice[Int], from: in Int, to: in Int, paraLevel: in Int): List[Int] {
  val n = to - from
  val acc: List[Int] = newList()
  if n <= 0 {
    return acc
  }
  var orig = Buf.filled(n, 0)
  var types = Buf.filled(n, 0)
  var levels = Buf.filled(n, paraLevel)
  var i = 0
  while i < n {
    val t = UnicodeData.bidiClassOf(cps[from + i])
    orig[i] = t
    types[i] = t
    i = i + 1
  }
  // BD9: the matching PDI of each isolate initiator, and the reverse.
  var matchPdi = Buf.filled(n, -1)
  var matchInit = Buf.filled(n, -1)
  val isoStack: List[Int] = newList()
  i = 0
  while i < n {
    if isIsolateInitiator(orig[i]) {
      isoStack.add(i)
    } else if orig[i] == classPDI and isoStack.count > 0 {
      val j = isoStack[isoStack.count - 1]
      isoStack.removeAt(isoStack.count - 1)
      matchPdi[j] = i
      matchInit[i] = j
    }
    i = i + 1
  }
  // X1 to X8
  val stLevel: List[Int] = newList()
  val stOverride: List[Int] = newList()
  val stIsolate: List[Bool] = newList()
  stLevel.add(paraLevel)
  stOverride.add(-1)
  stIsolate.add(false)
  var overflowIsolate = 0
  var overflowEmbedding = 0
  var validIsolate = 0
  i = 0
  while i < n {
    val t = orig[i]
    val top = stLevel.count - 1
    if t == classRLE or t == classLRE or t == classRLO or t == classLRO {
      levels[i] = stLevel[top]
      val nl = if t == classRLE or t == classRLO { nextOdd(stLevel[top]) } else { nextEven(stLevel[top]) }
      if nl <= maxDepth and overflowIsolate == 0 and overflowEmbedding == 0 {
        stLevel.add(nl)
        stOverride.add(if t == classRLO { classR } else if t == classLRO { classL } else { -1 })
        stIsolate.add(false)
      } else if overflowIsolate == 0 {
        overflowEmbedding = overflowEmbedding + 1
      }
    } else if isIsolateInitiator(t) {
      levels[i] = stLevel[top]
      if stOverride[top] >= 0 {
        types[i] = stOverride[top]
      }
      val rtl = if t == classRLI {
        true
      } else if t == classLRI {
        false
      } else {
        paragraphLevelOf(cps, from + i + 1, from + (if matchPdi[i] >= 0 { matchPdi[i] } else { n })) == 1
      }
      val nl = if rtl { nextOdd(stLevel[top]) } else { nextEven(stLevel[top]) }
      if nl <= maxDepth and overflowIsolate == 0 and overflowEmbedding == 0 {
        validIsolate = validIsolate + 1
        stLevel.add(nl)
        stOverride.add(-1)
        stIsolate.add(true)
      } else {
        overflowIsolate = overflowIsolate + 1
      }
    } else if t == classPDI {
      if overflowIsolate > 0 {
        overflowIsolate = overflowIsolate - 1
      } else if validIsolate > 0 {
        overflowEmbedding = 0
        while not stIsolate[stIsolate.count - 1] {
          stLevel.removeAt(stLevel.count - 1)
          stOverride.removeAt(stOverride.count - 1)
          stIsolate.removeAt(stIsolate.count - 1)
        }
        stLevel.removeAt(stLevel.count - 1)
        stOverride.removeAt(stOverride.count - 1)
        stIsolate.removeAt(stIsolate.count - 1)
        validIsolate = validIsolate - 1
      }
      val tp = stLevel.count - 1
      levels[i] = stLevel[tp]
      if stOverride[tp] >= 0 {
        types[i] = stOverride[tp]
      }
    } else if t == classPDF {
      levels[i] = stLevel[top]
      if overflowIsolate == 0 {
        if overflowEmbedding > 0 {
          overflowEmbedding = overflowEmbedding - 1
        } else if not stIsolate[top] and stLevel.count >= 2 {
          stLevel.removeAt(top)
          stOverride.removeAt(top)
          stIsolate.removeAt(top)
        }
      }
    } else if t == classB {
      levels[i] = paraLevel
    } else if t == classBN {
      levels[i] = stLevel[top]
    } else {
      levels[i] = stLevel[top]
      if stOverride[top] >= 0 {
        types[i] = stOverride[top]
      }
    }
    i = i + 1
  }
  // X9: the characters left out of the rest.
  val keep: List[Int] = newList()
  var keepPos = Buf.filled(n, -1)
  i = 0
  while i < n {
    if not isRemovedByX9(orig[i]) {
      keepPos[i] = keep.count
      keep.add(i)
    }
    i = i + 1
  }
  // X10: level runs, chained into isolating run sequences.
  val runFirst: List[Int] = newList()
  val runLast: List[Int] = newList()
  var runOf = Buf.filled(n, -1)
  var runStartingAt = Buf.filled(n, -1)
  var k = 0
  while k < keep.count {
    var e = k
    while e + 1 < keep.count and levels[keep[e + 1]] == levels[keep[k]] {
      e = e + 1
    }
    val r = runFirst.count
    runFirst.add(keep[k])
    runLast.add(keep[e])
    runStartingAt[keep[k]] = r
    var q = k
    while q <= e {
      runOf[keep[q]] = r
      q = q + 1
    }
    k = e + 1
  }
  var res = Buf.filled(n, paraLevel)
  var r = 0
  while r < runFirst.count {
    val c0 = runFirst[r]
    val chained = orig[c0] == classPDI and matchInit[c0] >= 0 and runLast[runOf[matchInit[c0]]] == matchInit[c0]
    if not chained {
      val seq: List[Int] = newList()
      var cur = r
      var more = true
      while more {
        var q = keepPos[runFirst[cur]]
        val lastPos = keepPos[runLast[cur]]
        while q <= lastPos {
          seq.add(keep[q])
          q = q + 1
        }
        val last = runLast[cur]
        more = false
        if isIsolateInitiator(orig[last]) and matchPdi[last] >= 0 and runStartingAt[matchPdi[last]] >= 0 {
          cur = runStartingAt[matchPdi[last]]
          more = true
        }
      }
      val level = levels[seq[0]]
      val firstPos = keepPos[seq[0]]
      val prevLevel = if firstPos == 0 { paraLevel } else { levels[keep[firstPos - 1]] }
      val lastChar = seq[seq.count - 1]
      val lastPos = keepPos[lastChar]
      val nextLevel = if isIsolateInitiator(orig[lastChar]) or lastPos + 1 >= keep.count {
        paraLevel
      } else {
        levels[keep[lastPos + 1]]
      }
      val sos = (if level > prevLevel { level } else { prevLevel }) % 2
      val eos = (if level > nextLevel { level } else { nextLevel }) % 2
      resolveSequence(cps, from, seq, types, orig, level, sos, eos, res)
    }
    r = r + 1
  }
  // The characters X9 removed take the level of the one before them.
  i = 0
  while i < n {
    if isRemovedByX9(orig[i]) {
      res[i] = if i == 0 { paraLevel } else { res[i - 1] }
    }
    i = i + 1
  }
  i = 0
  while i < n {
    acc.add(res[i])
    i = i + 1
  }
  acc
}

/// The runs of the line `lineFrom ..< lineTo` of a paragraph in visual order, from left to right
/// (rules L1 and L2).  `levels` are the paragraph's from `resolveLevels` for the paragraph that
/// starts at code point `paraFrom`.  Whitespace at the end of the line, and before a separator, takes the
/// paragraph's direction.
pub func lineRuns(
  cps: in slice[Int],
  paraFrom: in Int,
  levels: in List[Int],
  lineFrom: in Int,
  lineTo: in Int,
  paraLevel: in Int,
): List[BidiRun] {
  val runs: List[BidiRun] = newList()
  val n = lineTo - lineFrom
  if n <= 0 {
    return runs
  }
  var lv = Buf.filled(n, 0)
  var j = 0
  while j < n {
    lv[j] = levels[lineFrom - paraFrom + j]
    j = j + 1
  }
  var trailing = true
  j = n - 1
  while j >= 0 {
    val t = UnicodeData.bidiClassOf(cps[lineFrom + j])
    if t == classB or t == classS {
      lv[j] = paraLevel
      trailing = true
    } else if t == classWS or isIsolateInitiator(t) or t == classPDI or isRemovedByX9(t) {
      if trailing {
        lv[j] = paraLevel
      }
    } else {
      trailing = false
    }
    j = j - 1
  }
  var i = 0
  while i < n {
    var e = i
    while e + 1 < n and lv[e + 1] == lv[i] {
      e = e + 1
    }
    runs.add(BidiRun(from = lineFrom + i, to = lineFrom + e + 1, level = lv[i]))
    i = e + 1
  }
  var highest = 0
  var lowestOdd = 1000
  for run in runs {
    if run.level > highest {
      highest = run.level
    }
    if run.level % 2 == 1 and run.level < lowestOdd {
      lowestOdd = run.level
    }
  }
  var order = Buf.filled(runs.count, 0)
  var q = 0
  while q < runs.count {
    order[q] = q
    q = q + 1
  }
  var level = highest
  while level >= lowestOdd {
    var a = 0
    while a < runs.count {
      if runs[order[a]].level >= level {
        var b = a
        while b + 1 < runs.count and runs[order[b + 1]].level >= level {
          b = b + 1
        }
        var lo = a
        var hi = b
        while lo < hi {
          val tmp = order[lo]
          order[lo] = order[hi]
          order[hi] = tmp
          lo = lo + 1
          hi = hi - 1
        }
        a = b + 1
      } else {
        a = a + 1
      }
    }
    level = level - 1
  }
  val visual: List[BidiRun] = newList()
  q = 0
  while q < runs.count {
    visual.add(runs[order[q]])
    q = q + 1
  }
  visual
}
