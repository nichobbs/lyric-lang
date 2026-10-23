//! wrap.l - Ui.Native.Wrap: soft-wrapped multi-line text, for the native host's text areas
//! (docs/67 G10, #8422).
//!
//! A value is cut into visual lines: at every newline, and again wherever a paragraph is wider than
//! the box.  A paragraph breaks after the last word that fits (the spaces after a word hang at the
//! end of its line); a word wider than the box breaks between code points.  Everything here is in
//! code points, like the caret, and takes the text's width from a function the caller supplies, so
//! the same lines come out in a test with a fixed-width font and in the window with the real one.
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

/// One visual line: the code points `from ..< to` of the value.  `hard` is true when a newline
/// code point follows (at index `to`), so the next line starts at `to + 1`; false for a line that
/// was cut by width and for the last line.
pub record VisualLine {
  from: Int
  to: Int
  hard: Bool
}

/// The part of one visual line a selection covers: code points `from ..< to`, and whether the
/// newline that ends the line is selected too.
pub record RowSpan {
  row: Int
  from: Int
  to: Int
  breakSelected: Bool
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

// The width of `from ..< to` without the spaces that end it: they hang past the edge of a line.
func widthWithoutTrailingSpaces(cps: slice[Int], from: Int, to: Int, widthOf: (String) -> Float): Float {
  var e = to
  while e > from and isSpace(cps[e - 1]) {
    e = e - 1
  }
  if e == from {
    0.0f32
  } else {
    widthOf(sliceOf(cps, from, e))
  }
}

// Where the paragraph `start ..< to`, which does not fit in `maxWidth`, ends its first line.
func breakPoint(cps: slice[Int], start: Int, to: Int, maxWidth: Float, widthOf: (String) -> Float): Int {
  var best = -1
  var i = start
  var scanning = true
  while scanning and i < to {
    var wordEnd = i
    while wordEnd < to and not isSpace(cps[wordEnd]) {
      wordEnd = wordEnd + 1
    }
    var next = wordEnd
    while next < to and isSpace(cps[next]) {
      next = next + 1
    }
    if next == i {
      next = i + 1
    }
    if widthWithoutTrailingSpaces(cps, start, wordEnd, widthOf) <= maxWidth {
      best = next
      i = next
    } else {
      scanning = false
    }
  }
  if best > start and best < to {
    return best
  }
  var k = start + 1
  while k < to and widthWithoutTrailingSpaces(cps, start, k + 1, widthOf) <= maxWidth {
    k = k + 1
  }
  k
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
  var start = from
  var done = false
  while not done {
    if widthWithoutTrailingSpaces(cps, start, to, widthOf) <= maxWidth or to - start <= 1 {
      lines.add(VisualLine(from = start, to = to, hard = followedByBreak))
      done = true
    } else {
      val brk = breakPoint(cps, start, to, maxWidth, widthOf)
      lines.add(VisualLine(from = start, to = brk, hard = false))
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

/// The x offset, from the left edge of line `row`, of code point `position` (clamped to the line).
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
  val l = lines[if row < 0 { 0 } else if row >= lines.count { lines.count - 1 } else { row }]
  val c = if position < l.from { l.from } else if position > l.to { l.to } else { position }
  if c == l.from {
    0.0f32
  } else {
    widthOf(sliceOf(codePoints(value), l.from, c))
  }
}

/// The x offset, from the left edge of its line, of a caret at code point `caret`.
pub func caretOffset(value: in String, lines: in List[VisualLine], caret: in Int, widthOf: in (String) -> Float): Float {
  offsetInRow(value, lines, lineIndexOf(lines, caret), caret, widthOf)
}

/// The caret position on line `row` nearest to `x` pixels from the left edge of the line.
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
  val r = if row < 0 { 0 } else if row >= lines.count { lines.count - 1 } else { row }
  val l = lines[r]
  val last = lastCaret(lines, r)
  val cps = codePoints(value)
  var best = l.from
  var bestDist = 1000000.0f32
  var c = l.from
  while c <= last {
    val w = if c == l.from { 0.0f32 } else { widthOf(sliceOf(cps, l.from, c)) }
    val d = if w > x { w - x } else { x - w }
    if d < bestDist {
      bestDist = d
      best = c
    }
    c = c + 1
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

/// The parts of each line the selection `from ..< to` covers, top to bottom.  An empty line in
/// the middle of a selection is a span of no width with its break selected.
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
