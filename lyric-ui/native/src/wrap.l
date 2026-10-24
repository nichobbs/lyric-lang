//! wrap.l - Ui.Native.Wrap: soft-wrapped multi-line text, for the native host's text areas
//! (docs/67 G10, #8422, #8410).
//!
//! A value is cut into visual lines: at every newline, and again wherever a paragraph is wider than
//! the box.  A paragraph breaks at the opportunities of the Unicode line breaking algorithm
//! (`Ui.Native.LineBreak`: after spaces and hyphens, between ideographs, never before closing
//! punctuation, and so on), after the last one that fits, and the spaces at the end of a line hang
//! past its edge; a word wider than the box breaks between characters, never inside a combining
//! sequence.  Everything here is in code points, like the caret, and takes the text's width from a
//! function the caller supplies, so the same lines come out in a test with a fixed-width font and in
//! the window with the real one.
//!
//! Text with right-to-left characters is laid out with the Unicode Bidirectional Algorithm
//! (`Ui.Native.Bidi`).  A paragraph takes its direction from its first strong character, a right to
//! left paragraph is aligned to the right of the box, and each line is a list of pieces in visual
//! order, each in one direction.  The caret, a click, a selection and Left and Right all work on the
//! pieces: a logical position is drawn at the trailing edge of the character before it (the leading
//! edge of the first character at the start of a line), so a position at the boundary of two pieces
//! has one place, and a selection that crosses pieces is one band per piece.  A line with no right
//! to left text is one piece from the left edge, and takes none of this.
//!
//! A caret at the very end of a line that was cut (not ended by a newline) is also at the start of
//! the next line; it is shown on the next line, so the end of a cut line is one code point short
//! (`lastCaret`), where a click or the End key puts the caret.
@pure
package Ui.Native.Wrap

import Std.Core
import Std.Collections
import Std.String
import Std.Encoding.{codepointToString}
import Ui.Native.Bidi
import Ui.Native.LineBreak
import Ui.Native.UnicodeData

/// One visual line: the code points `from ..< to` of the value.  `hard` is true when a newline
/// code point follows (at index `to`), so the next line starts at `to + 1`; false for a line that
/// was cut by width and for the last line.  `rtl` is true when the line's paragraph is right to
/// left.  The spaces at the end of the line (`visibleTo ..< to`) hang past its edge; `runs` are the
/// stretches of `from ..< visibleTo` in one direction, in visual order, empty for a line that is
/// all left to right.  `width` is the width of the box the line was cut for.
pub record VisualLine {
  from: Int
  to: Int
  hard: Bool
  rtl: Bool
  visibleTo: Int
  width: Float
  runs: List[Bidi.BidiRun]
}

/// The part of one visual line a selection covers: code points `from ..< to`, and whether the
/// newline that ends the line is selected too.
pub record RowSpan {
  row: Int
  from: Int
  to: Int
  breakSelected: Bool
}

/// A stretch of a line drawn in one direction: code points `from ..< to`, `x` pixels from the left
/// of the box and `width` wide; an odd `level` is drawn right to left.  `text` is what to draw,
/// from `textX` pixels: the piece in reading order without the spaces at its ends (a shaper drops
/// those, and they are only room).  The painter lays it out in the piece's direction
/// (`Text.layoutRun`), which orders its words, joins its Arabic letters and swaps its brackets.
pub record Piece {
  from: Int
  to: Int
  level: Int
  x: Float
  width: Float
  text: String
  textX: Float
}

/// A rectangle of a selection on line `row`, from `x0` to `x1` pixels from the left of the box.
pub record Band {
  row: Int
  x0: Float
  x1: Float
}

func isSpace(cp: Int): Bool {
  cp == 32 or cp == 9 or cp == 160 or cp == 12288
}

func sliceOf(cps: slice[Int], from: Int, to: Int): String {
  val sb = StringBuilder.new()
  var i = from
  while i < to {
    StringBuilder.append(sb, codepointToString(cps[i]))
    i = i + 1
  }
  StringBuilder.toString(sb)
}

// The advance of one space-like code point, measured between two letters: a shaper drops the
// spaces at the start and end of a text it is given, so they cannot be measured on their own.
func spaceAdvance(cp: Int, widthOf: (String) -> Float): Float {
  widthOf("x" + codepointToString(cp) + "x") - widthOf("xx")
}

// The width of `from ..< to`, the characters in the order of the text: the text between its spaces
// as it is measured, and each space at either end by its advance.
func spanWidth(cps: slice[Int], from: Int, to: Int, widthOf: (String) -> Float): Float {
  var a = from
  while a < to and isSpace(cps[a]) {
    a = a + 1
  }
  var z = to
  while z > a and isSpace(cps[z - 1]) {
    z = z - 1
  }
  var w = if z > a { widthOf(sliceOf(cps, a, z)) } else { 0.0f32 }
  var i = from
  while i < a {
    w = w + spaceAdvance(cps[i], widthOf)
    i = i + 1
  }
  i = z
  while i < to {
    w = w + spaceAdvance(cps[i], widthOf)
    i = i + 1
  }
  w
}

// The width of `from ..< to` without the spaces that end it: they hang past the edge of a line.
func widthWithoutTrailingSpaces(cps: slice[Int], from: Int, to: Int, widthOf: (String) -> Float): Float {
  var e = to
  while e > from and isSpace(cps[e - 1]) {
    e = e - 1
  }
  spanWidth(cps, from, e, widthOf)
}

// Where the paragraph `start ..< to`, which does not fit in `maxWidth`, ends its first line:
// after the last line break opportunity that fits, or, with none, after as many characters as fit.
// `breaks` are the opportunities of the paragraph that starts at `paraFrom`.
func breakPoint(
  cps: slice[Int],
  paraFrom: Int,
  breaks: List[Int],
  start: Int,
  to: Int,
  maxWidth: Float,
  widthOf: (String) -> Float,
): Int {
  var best = -1
  var o = start + 1
  var scanning = true
  while scanning and o < to {
    if breaks[o - paraFrom] != LineBreak.noBreak {
      if widthWithoutTrailingSpaces(cps, start, o, widthOf) <= maxWidth {
        best = o
      } else {
        scanning = false
      }
    }
    o = o + 1
  }
  if best > start {
    return best
  }
  var k = start + 1
  while k < to and widthWithoutTrailingSpaces(cps, start, k + 1, widthOf) <= maxWidth {
    k = k + 1
  }
  while k < to and LineBreak.joinsPrevious(cps, k) {
    k = k + 1
  }
  k
}

// One line `start ..< end` of a paragraph that begins at `paraFrom`.
func makeLine(
  cps: slice[Int],
  paraFrom: Int,
  levels: List[Int],
  paraLevel: Int,
  start: Int,
  stop: Int,
  hard: Bool,
  maxWidth: Float,
): VisualLine {
  var visible = stop
  while visible > start and isSpace(cps[visible - 1]) {
    visible = visible - 1
  }
  var runs: List[Bidi.BidiRun] = newList()
  if levels.count > 0 and visible > start {
    runs = Bidi.lineRuns(cps, paraFrom, levels, start, visible, paraLevel)
    if paraLevel == 0 and runs.count == 1 and runs[0].level == 0 {
      runs = newList()
    }
  }
  VisualLine(
    from = start,
    to = stop,
    hard = hard,
    rtl = paraLevel == 1,
    visibleTo = visible,
    width = maxWidth,
    runs = runs
  )
}

func wrapParagraph(
  cps: slice[Int],
  from: Int,
  to: Int,
  followedByBreak: Bool,
  maxWidth: Float,
  widthOf: (String) -> Float,
  lines: List[VisualLine],
): Unit {
  val breaks = LineBreak.breaksIn(cps, from, to)
  val bidi = Bidi.needsBidi(cps, from, to)
  val paraLevel = if bidi { Bidi.paragraphLevelOf(cps, from, to) } else { 0 }
  val levels: List[Int] = if bidi { Bidi.resolveLevels(cps, from, to, paraLevel) } else { newList() }
  var start = from
  var done = false
  while not done {
    if widthWithoutTrailingSpaces(cps, start, to, widthOf) <= maxWidth or to - start <= 1 {
      lines.add(makeLine(cps, from, levels, paraLevel, start, to, followedByBreak, maxWidth))
      done = true
    } else {
      val brk = breakPoint(cps, from, breaks, start, to, maxWidth, widthOf)
      lines.add(makeLine(cps, from, levels, paraLevel, start, brk, false, maxWidth))
      start = brk
    }
  }
}

/// The visual lines of `value` in a box `maxWidth` pixels wide.  There is always at least one
/// (empty) line, and a value that ends in a newline ends in an empty line.
pub func wrapLines(value: in String, maxWidth: in Float, widthOf: in (String) -> Float): List[VisualLine] {
  val cps = codePoints(value)
  val n = cps.length
  val lines: List[VisualLine] = newList()
  var start = 0
  var i = 0
  while i <= n {
    if i == n or cps[i] == 10 {
      wrapParagraph(cps, start, i, i < n, maxWidth, widthOf, lines)
      start = i + 1
    }
    i = i + 1
  }
  lines
}

/// The line a caret at code point `caret` is shown on.
pub func lineIndexOf(lines: in List[VisualLine], caret: in Int): Int {
  var i = 0
  while i < lines.count {
    val l = lines[i]
    if caret < l.to {
      return i
    }
    if caret == l.to and (l.hard or i == lines.count - 1) {
      return i
    }
    i = i + 1
  }
  if lines.count == 0 {
    0
  } else {
    lines.count - 1
  }
}

/// The last caret position that stays on line `row`: its end, or one short of it for a line that
/// was cut (see the module comment).
pub func lastCaret(lines: in List[VisualLine], row: in Int): Int {
  val l = lines[row]
  if l.hard or row == lines.count - 1 or l.to <= l.from {
    l.to
  } else {
    l.to - 1
  }
}

/// The first caret position of line `row`.
pub func firstCaret(lines: in List[VisualLine], row: in Int): Int {
  lines[row].from
}

// A line with no right to left text, drawn from the left edge in one piece.
func isPlain(l: VisualLine): Bool {
  not l.rtl and l.runs.count == 0
}

func clampRow(lines: List[VisualLine], row: Int): Int {
  if row < 0 {
    0
  } else if row >= lines.count {
    lines.count - 1
  } else {
    row
  }
}

// The pieces of a line, in visual order, with their places.  A right to left paragraph is aligned
// to the right of its box.
func buildPieces(cps: slice[Int], l: VisualLine, widthOf: (String) -> Float): List[Piece] {
  val pieces: List[Piece] = newList()
  val runs: List[Bidi.BidiRun] = newList()
  if l.runs.count > 0 {
    for r in l.runs {
      runs.add(r)
    }
  } else if l.visibleTo > l.from {
    runs.add(Bidi.BidiRun(from = l.from, to = l.visibleTo, level = if l.rtl { 1 } else { 0 }))
  }
  val widths: List[Float] = newList()
  var total = 0.0f32
  for r in runs {
    val w = spanWidth(cps, r.from, r.to, widthOf)
    widths.add(w)
    total = total + w
  }
  var x = if l.rtl and l.width > total { l.width - total } else { 0.0f32 }
  var i = 0
  while i < runs.count {
    val r = runs[i]
    var a = r.from
    while a < r.to and isSpace(cps[a]) {
      a = a + 1
    }
    var z = r.to
    while z > a and isSpace(cps[z - 1]) {
      z = z - 1
    }
    val before = spanWidth(cps, r.from, a, widthOf)
    val after = spanWidth(cps, z, r.to, widthOf)
    pieces.add(
      Piece(
        from = r.from,
        to = r.to,
        level = r.level,
        x = x,
        width = widths[i],
        text = if z > a { sliceOf(cps, a, z) } else { "" },
        textX = x + (if r.level % 2 == 1 { after } else { before })
      )
    )
    x = x + widths[i]
    i = i + 1
  }
  pieces
}

// Where the pieces of an empty line would start.
func emptyOrigin(l: VisualLine): Float {
  if l.rtl and l.width > 0.0f32 {
    l.width
  } else {
    0.0f32
  }
}

// The x offset of the logical position `c` (see the module comment for which edge it is).
func positionX(cps: slice[Int], l: VisualLine, pieces: List[Piece], c: Int, widthOf: (String) -> Float): Float {
  val cc = if c < l.from { l.from } else if c > l.to { l.to } else { c }
  if cc > l.visibleTo {
    val hang = spanWidth(cps, l.visibleTo, cc, widthOf)
    if l.rtl {
      val left = if pieces.count > 0 { pieces[0].x } else { emptyOrigin(l) }
      return left - hang
    }
    val right = if pieces.count > 0 { pieces[pieces.count - 1].x + pieces[pieces.count - 1].width } else { 0.0f32 }
    return right + hang
  }
  if pieces.count == 0 {
    return emptyOrigin(l)
  }
  if cc == l.from {
    for p in pieces {
      if p.from == cc {
        return if p.level % 2 == 1 { p.x + p.width } else { p.x }
      }
    }
    return emptyOrigin(l)
  }
  for p in pieces {
    if p.from < cc and cc <= p.to {
      return if p.level % 2 == 1 {
        p.x + spanWidth(cps, cc, p.to, widthOf)
      } else {
        p.x + spanWidth(cps, p.from, cc, widthOf)
      }
    }
  }
  emptyOrigin(l)
}

/// The x offset, from the left edge of the box, of code point `position` on line `row` (clamped to
/// the line).
pub func offsetInRow(
  value: in String,
  lines: in List[VisualLine],
  row: in Int,
  position: in Int,
  widthOf: in (String) -> Float,
): Float {
  if lines.count == 0 {
    return 0.0f32
  }
  val l = lines[clampRow(lines, row)]
  val cps = codePoints(value)
  if isPlain(l) {
    val c = if position < l.from { l.from } else if position > l.to { l.to } else { position }
    return spanWidth(cps, l.from, c, widthOf)
  }
  positionX(cps, l, buildPieces(cps, l, widthOf), position, widthOf)
}

/// The x offset, from the left edge of the box, of a caret at code point `caret`.
pub func caretOffset(value: in String, lines: in List[VisualLine], caret: in Int, widthOf: in (String) -> Float): Float {
  offsetInRow(value, lines, lineIndexOf(lines, caret), caret, widthOf)
}

/// The caret position on line `row` nearest to `x` pixels from the left edge of the box.
pub func positionAt(
  value: in String,
  lines: in List[VisualLine],
  row: in Int,
  x: in Float,
  widthOf: in (String) -> Float,
): Int {
  if lines.count == 0 {
    return 0
  }
  val r = clampRow(lines, row)
  val l = lines[r]
  val last = lastCaret(lines, r)
  val cps = codePoints(value)
  val plain = isPlain(l)
  val pieces: List[Piece] = if plain { newList() } else { buildPieces(cps, l, widthOf) }
  var best = l.from
  var bestDist = 1000000.0f32
  var c = l.from
  while c <= last {
    val w = if plain { spanWidth(cps, l.from, c, widthOf) } else { positionX(cps, l, pieces, c, widthOf) }
    val d = if w > x { w - x } else { x - w }
    if d < bestDist {
      bestDist = d
      best = c
    }
    c = c + 1
  }
  best
}

/// True when the line `caret` is on has right to left text in it or belongs to a right to left
/// paragraph, so that a step on screen is not a step in the text.
pub func isMixedAt(lines: in List[VisualLine], caret: in Int): Bool {
  if lines.count == 0 {
    return false
  }
  not isPlain(lines[lineIndexOf(lines, caret)])
}

// The index in `pieces` of the one with the character at `k`, or -1.
func pieceOfChar(pieces: List[Piece], k: Int): Int {
  var i = 0
  while i < pieces.count {
    if pieces[i].from <= k and k < pieces[i].to {
      return i
    }
    i = i + 1
  }
  0 - 1
}

// The piece a caret at `c` is drawn against: the one of the character before it, or at the start
// of a line the one after.
func pieceOfCaret(pieces: List[Piece], l: VisualLine, c: Int): Int {
  if c > l.from {
    pieceOfChar(pieces, c - 1)
  } else {
    pieceOfChar(pieces, c)
  }
}

/// The caret position one step left (`delta` -1) or right (1) of `caret` on screen, on its line.
/// Places that are drawn at the same x are not told apart: the one in the piece the caret is
/// already in wins, so that stepping through a word in the other direction stays in it.  At the
/// edge of the line the caret moves on in the text, by one in the order of the line's paragraph,
/// to the neighbouring line.  For a line that is all left to right this is a step in the text.
pub func stepVisual(
  value: in String,
  lines: in List[VisualLine],
  caret: in Int,
  delta: in Int,
  widthOf: in (String) -> Float,
): Int {
  val cps = codePoints(value)
  val n = cps.length
  if lines.count == 0 {
    return if caret + delta < 0 { 0 } else if caret + delta > n { n } else { caret + delta }
  }
  val r = lineIndexOf(lines, caret)
  val l = lines[r]
  val pieces = buildPieces(cps, l, widthOf)
  val here = positionX(cps, l, pieces, caret, widthOf)
  val herePiece = pieceOfCaret(pieces, l, caret)
  val last = lastCaret(lines, r)
  var best = caret
  var bestDist = 1000000.0f32
  var bestSamePiece = false
  var c = l.from
  while c <= last {
    val x = positionX(cps, l, pieces, c, widthOf)
    val ahead = if delta < 0 { here - x } else { x - here }
    if ahead > 0.01f32 {
      val samePiece = pieceOfCaret(pieces, l, c) == herePiece
      if ahead < bestDist - 0.01f32 or (ahead < bestDist + 0.01f32 and samePiece and not bestSamePiece) {
        bestDist = ahead
        best = c
        bestSamePiece = samePiece
      }
    }
    c = c + 1
  }
  if best == caret {
    val logical = if l.rtl { 0 - delta } else { delta }
    val moved = caret + logical
    return if moved < 0 { 0 } else if moved > n { n } else { moved }
  }
  best
}

/// The line under `y` pixels from the top of the text, clamped to the first and last line.
pub func rowAtY(lines: in List[VisualLine], y: in Float, lineHeight: in Float): Int {
  if lines.count == 0 or lineHeight <= 0.0f32 or y < 0.0f32 {
    return 0
  }
  val r = (y / lineHeight).toInt()
  if r >= lines.count {
    lines.count - 1
  } else {
    r
  }
}

/// The height of all the lines.
pub func contentHeight(lines: in List[VisualLine], lineHeight: in Float): Float {
  lines.count.toFloat() * lineHeight
}

/// The scroll offset that shows line `row` in a view `viewHeight` tall, given the current one.
pub func scrollToRow(scroll: in Float, row: in Int, lineHeight: in Float, viewHeight: in Float): Float {
  val top = row.toFloat() * lineHeight
  val bottom = top + lineHeight
  if top < scroll {
    top
  } else if bottom > scroll + viewHeight {
    bottom - viewHeight
  } else {
    scroll
  }
}

/// The parts of each line the selection `from ..< to` covers, top to bottom, in code points.  An
/// empty line in the middle of a selection is a span of no width with its break selected.
pub func selectionRows(lines: in List[VisualLine], from: in Int, to: in Int): List[RowSpan] {
  val spans: List[RowSpan] = newList()
  if to <= from {
    return spans
  }
  var i = 0
  while i < lines.count {
    val l = lines[i]
    val a = if from > l.from { from } else { l.from }
    val b = if to < l.to { to } else { l.to }
    val breakSelected = l.hard and from <= l.to and to > l.to
    if a < b or breakSelected {
      spans.add(
        RowSpan(
          row = i,
          from = if a < b { a } else { l.to },
          to = if a < b { b } else { l.to },
          breakSelected = breakSelected
        )
      )
    }
    i = i + 1
  }
  spans
}

/// The pieces of line `row` to draw, in visual order.  A line with no right to left text is one
/// piece, all of it, from the left edge.
pub func linePieces(
  value: in String, lines: in List[VisualLine], row: in Int, widthOf: in (String) -> Float
): List[Piece] {
  if lines.count == 0 {
    return newList()
  }
  val l = lines[clampRow(lines, row)]
  val cps = codePoints(value)
  if isPlain(l) {
    val one: List[Piece] = newList()
    var a = l.from
    while a < l.to and isSpace(cps[a]) {
      a = a + 1
    }
    var z = l.to
    while z > a and isSpace(cps[z - 1]) {
      z = z - 1
    }
    if z > a {
      one.add(
        Piece(
          from = l.from,
          to = l.to,
          level = 0,
          x = 0.0f32,
          width = 0.0f32,
          text = sliceOf(cps, a, z),
          textX = spanWidth(cps, l.from, a, widthOf)
        )
      )
    }
    return one
  }
  buildPieces(cps, l, widthOf)
}

// The extent of a line's text, trailing spaces included: its left and right edges.
func lineEdges(cps: slice[Int], l: VisualLine, pieces: List[Piece], widthOf: (String) -> Float): List[Float] {
  var left = emptyOrigin(l)
  var right = left
  if pieces.count > 0 {
    left = pieces[0].x
    right = pieces[pieces.count - 1].x + pieces[pieces.count - 1].width
  }
  val hang = spanWidth(cps, l.visibleTo, l.to, widthOf)
  if l.rtl {
    left = left - hang
  } else {
    right = right + hang
  }
  val edges: List[Float] = newList()
  edges.add(left)
  edges.add(right)
  edges
}

// Adds the band `x0 ..< x1` on `row`, joined to one that touches it.
func addBand(bands: List[Band], row: Int, x0: Float, x1: Float): Unit {
  var i = 0
  while i < bands.count {
    val b = bands[i]
    if b.row == row and x0 <= b.x1 + 0.5f32 and x1 >= b.x0 - 0.5f32 {
      val nx0 = if x0 < b.x0 { x0 } else { b.x0 }
      val nx1 = if x1 > b.x1 { x1 } else { b.x1 }
      bands.removeAt(i)
      addBand(bands, row, nx0, nx1)
      return
    }
    i = i + 1
  }
  bands.add(Band(row = row, x0 = x0, x1 = x1))
}

/// The rectangles the selection `from ..< to` covers, top to bottom: one per piece of each line it
/// touches, touching ones joined.  The newline that ends a selected line is a band of six pixels
/// past the line's end, on the side its paragraph reads towards.
pub func selectionBands(
  value: in String,
  lines: in List[VisualLine],
  from: in Int,
  to: in Int,
  widthOf: in (String) -> Float,
): List[Band] {
  val bands: List[Band] = newList()
  if to <= from {
    return bands
  }
  val cps = codePoints(value)
  var i = 0
  while i < lines.count {
    val l = lines[i]
    val a = if from > l.from { from } else { l.from }
    val b = if to < l.to { to } else { l.to }
    val breakSelected = l.hard and from <= l.to and to > l.to
    if a < b or breakSelected {
      val plain = isPlain(l)
      val pieces: List[Piece] = if plain { newList() } else { buildPieces(cps, l, widthOf) }
      if a < b {
        if plain {
          addBand(bands, i, spanWidth(cps, l.from, a, widthOf), spanWidth(cps, l.from, b, widthOf))
        } else {
          for p in pieces {
            val s = if a > p.from { a } else { p.from }
            val e = if b < p.to { b } else { p.to }
            if s < e {
              val lo = if p.level % 2 == 1 {
                p.x + spanWidth(cps, e, p.to, widthOf)
              } else {
                p.x + spanWidth(cps, p.from, s, widthOf)
              }
              val hi = if p.level % 2 == 1 {
                p.x + spanWidth(cps, s, p.to, widthOf)
              } else {
                p.x + spanWidth(cps, p.from, e, widthOf)
              }
              addBand(bands, i, lo, hi)
            }
          }
          val sa = if a > l.visibleTo { a } else { l.visibleTo }
          if sa < b {
            val xa = positionX(cps, l, pieces, sa, widthOf)
            val xb = positionX(cps, l, pieces, b, widthOf)
            addBand(bands, i, if xa < xb { xa } else { xb }, if xa < xb { xb } else { xa })
          }
        }
      }
      if breakSelected {
        if plain {
          val edge = spanWidth(cps, l.from, l.to, widthOf)
          addBand(bands, i, edge, edge + 6.0f32)
        } else {
          val edges = lineEdges(cps, l, pieces, widthOf)
          if l.rtl {
            addBand(bands, i, edges[0] - 6.0f32, edges[0])
          } else {
            addBand(bands, i, edges[1], edges[1] + 6.0f32)
          }
        }
      }
    }
    i = i + 1
  }
  bands
}
