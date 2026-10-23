@test_module
package Ui.Native.WrapTests

import Std.Core
import Std.Collections
import Std.String
import Std.Testing
import Ui.Native.Wrap
import Ui.Native.Interact

// A font where every code point is ten pixels wide, so the lines are easy to work out by hand.
func tenWide(s: String): Float {
  Interact.cpCount(s).toFloat() * 10.0f32
}

func textOfLine(value: String, l: Wrap.VisualLine): String {
  Interact.cpSlice(value, l.from, l.to)
}

func lineTexts(value: String, width: Float): List[String] {
  val lines = Wrap.wrapLines(value, width, { s: String -> tenWide(s) })
  val texts: List[String] = newList()
  for l in lines {
    texts.add(textOfLine(value, l))
  }
  texts
}

func joined(xs: List[String]): String {
  var s = ""
  var first = true
  for x in xs {
    s = s + (if first { "" } else { "|" }) + x
    first = false
  }
  s
}

test "text that fits is one line" {
  assertEqual(joined(lineTexts("hello world", 200.0f32)), "hello world", "fits")
  assertEqual(joined(lineTexts("", 200.0f32)), "", "empty text is one empty line")
  assertEqualInt(Wrap.wrapLines("", 200.0f32, { s: String -> tenWide(s) }).count, 1, "one line")
}

test "a paragraph breaks after the last word that fits, and the spaces hang" {
  assertEqual(joined(lineTexts("aaa bbb ccc", 70.0f32)), "aaa bbb |ccc", "two lines")
  assertEqual(joined(lineTexts("aaa bbb ccc", 40.0f32)), "aaa |bbb |ccc", "one word each")
  assertEqual(joined(lineTexts("aaa   bbb", 40.0f32)), "aaa   |bbb", "a run of spaces stays with the word before it")
}

test "a word wider than the box breaks between code points" {
  assertEqual(joined(lineTexts("abcdefghij", 40.0f32)), "abcd|efgh|ij", "cut every four")
  assertEqual(
    joined(lineTexts("ab abcdefgh", 40.0f32)),
    "ab |abcd|efgh",
    "the long word starts a new line, then breaks"
  )
  assertEqual(
    joined(lineTexts("abcdef", 5.0f32)),
    "a|b|c|d|e|f",
    "a box narrower than a code point still makes progress"
  )
}

test "newlines end lines, and a trailing newline leaves an empty last line" {
  assertEqual(joined(lineTexts("one\ntwo", 200.0f32)), "one|two", "two lines")
  assertEqual(joined(lineTexts("one\n\ntwo", 200.0f32)), "one||two", "an empty line between")
  assertEqual(joined(lineTexts("one\n", 200.0f32)), "one|", "an empty line at the end")
  val lines = Wrap.wrapLines("one\ntwo", 200.0f32, { s: String -> tenWide(s) })
  assertTrue(lines[0].hard, "the first line is ended by a newline")
  assertFalse(lines[1].hard, "the last line is not")
  assertEqualInt(lines[1].from, 4, "the next line starts after the newline")
}

test "each cut and each newline keeps every code point in exactly one line" {
  val value = "the quick brown fox\njumps over the lazy dog and keeps running"
  val lines = Wrap.wrapLines(value, 90.0f32, { s: String -> tenWide(s) })
  var covered = 0
  var next = 0
  for l in lines {
    assertEqualInt(l.from, next, "lines are contiguous")
    covered = covered + (l.to - l.from)
    next = l.to + (if l.hard { 1 } else { 0 })
  }
  assertEqualInt(covered + 1, Interact.cpCount(value), "all but the newline are shown")
}

test "a caret at a cut belongs to the next line, a caret before a newline to its own" {
  val value = "aaa bbb ccc"
  val lines = Wrap.wrapLines(value, 70.0f32, { s: String -> tenWide(s) })
  assertEqualInt(Wrap.lineIndexOf(lines, 8), 1, "the cut is the start of the second line")
  assertEqualInt(Wrap.lineIndexOf(lines, 7), 0, "before the hanging space is the first line")
  assertEqualInt(Wrap.lineIndexOf(lines, 11), 1, "the end of the text")
  val hard = Wrap.wrapLines("ab\ncd", 200.0f32, { s: String -> tenWide(s) })
  assertEqualInt(Wrap.lineIndexOf(hard, 2), 0, "the end of a line ended by a newline")
  assertEqualInt(Wrap.lineIndexOf(hard, 3), 1, "after the newline")
  assertEqualInt(Wrap.lastCaret(lines, 0), 7, "the last caret of a cut line is one short")
  assertEqualInt(Wrap.lastCaret(hard, 0), 2, "the last caret of a hard line is its end")
}

test "the caret is placed by line and by distance along it" {
  val value = "aaa bbb ccc"
  val lines = Wrap.wrapLines(value, 70.0f32, { s: String -> tenWide(s) })
  assertEqualInt(Wrap.positionAt(value, lines, 0, 0.0f32, { s: String -> tenWide(s) }), 0, "start of the first line")
  assertEqualInt(Wrap.positionAt(value, lines, 0, 22.0f32, { s: String -> tenWide(s) }), 2, "nearest boundary")
  assertEqualInt(
    Wrap.positionAt(value, lines, 0, 500.0f32, { s: String -> tenWide(s) }),
    7,
    "past the end stays on the line"
  )
  assertEqualInt(Wrap.positionAt(value, lines, 1, 0.0f32, { s: String -> tenWide(s) }), 8, "start of the second line")
  assertEqualInt(Wrap.positionAt(value, lines, 1, 500.0f32, { s: String -> tenWide(s) }), 11, "end of the last line")
  assertEqualInt(
    Wrap.positionAt(value, lines, 9, 0.0f32, { s: String -> tenWide(s) }),
    8,
    "a row past the last is the last"
  )
  assertTrue(
    Wrap.caretOffset(value, lines, 10, { s: String -> tenWide(s) }) == 20.0f32,
    "two code points along the second line"
  )
  assertEqualInt(Wrap.rowAtY(lines, 25.0f32, 20.0f32), 1, "y to row")
  assertEqualInt(Wrap.rowAtY(lines, 999.0f32, 20.0f32), 1, "clamped to the last row")
  assertEqualInt(Wrap.rowAtY(lines, -5.0f32, 20.0f32), 0, "clamped to the first row")
}

test "a selection is cut into the part on each line" {
  val value = "aaa bbb ccc\nddd"
  val lines = Wrap.wrapLines(value, 70.0f32, { s: String -> tenWide(s) })
  val spans = Wrap.selectionRows(lines, 2, 13)
  assertEqualInt(spans.count, 3, "it crosses three lines")
  assertEqualInt(spans[0].from, 2, "starts inside the first line")
  assertEqualInt(spans[0].to, 8, "to the end of the first line")
  assertFalse(spans[0].breakSelected, "a cut is not a newline")
  assertTrue(spans[1].breakSelected, "the newline after the second line is selected")
  assertEqualInt(spans[2].from, 12, "the third line from its start")
  assertEqualInt(spans[2].to, 13, "to the selection end")
  assertEqualInt(Wrap.selectionRows(lines, 5, 5).count, 0, "an empty selection has no spans")
}

test "scrolling keeps the caret's line in view" {
  assertTrue(Wrap.scrollToRow(0.0f32, 1, 20.0f32, 60.0f32) == 0.0f32, "already in view")
  assertTrue(Wrap.scrollToRow(0.0f32, 4, 20.0f32, 60.0f32) == 40.0f32, "scrolls down to the row")
  assertTrue(Wrap.scrollToRow(100.0f32, 2, 20.0f32, 60.0f32) == 40.0f32, "scrolls up to the row")
}

test "Up and Down keep to a column across lines of different length" {
  val value = "abcdefgh\nab\nabcdefgh"
  val lines = Wrap.wrapLines(value, 200.0f32, { s: String -> tenWide(s) })
  val start = Interact.moveCaret(value, Interact.emptyEdit(), 6, false)
  val down = Interact.moveVertical(value, lines, start, 1, false, { s: String -> tenWide(s) })
  assertEqualInt(down.caret, 11, "the short line ends at its end")
  val again = Interact.moveVertical(value, lines, down, 1, false, { s: String -> tenWide(s) })
  assertEqualInt(again.caret, 18, "the column of the first line is remembered")
  val up = Interact.moveVertical(value, lines, again, -1, false, { s: String -> tenWide(s) })
  assertEqualInt(up.caret, 11, "and back up")
  val top = Interact.moveVertical(
    value,
    lines,
    Interact.moveCaret(value, Interact.emptyEdit(), 3, false),
    -1,
    false,
    { s: String -> tenWide(s) }
  )
  assertEqualInt(top.caret, 0, "Up on the first line goes to the start")
  val bottom = Interact.moveVertical(value, lines, again, 1, false, { s: String -> tenWide(s) })
  assertEqualInt(bottom.caret, Interact.cpCount(value), "Down on the last line goes to the end")
}

test "a horizontal move or an edit forgets the remembered column" {
  val value = "abcdefgh\nab"
  val lines = Wrap.wrapLines(value, 200.0f32, { s: String -> tenWide(s) })
  val down = Interact.moveVertical(
    value,
    lines,
    Interact.moveCaret(value, Interact.emptyEdit(), 6, false),
    1,
    false,
    { s: String -> tenWide(s) }
  )
  assertTrue(down.goalX >= 0.0f32, "Down remembers a column")
  assertTrue(Interact.stepCaret(value, down, 1, false).goalX < 0.0f32, "Left and Right forget it")
  assertTrue(Interact.insertText(value, down, "x", 0).edit.goalX < 0.0f32, "typing forgets it")
}

test "Shift with Up and Down extends the selection over lines" {
  val value = "abc\ndef"
  val lines = Wrap.wrapLines(value, 200.0f32, { s: String -> tenWide(s) })
  val from = Interact.moveCaret(value, Interact.emptyEdit(), 1, false)
  val sel = Interact.moveVertical(value, lines, from, 1, true, { s: String -> tenWide(s) })
  assertEqual(Interact.selectedText(value, sel), "bc\nd", "from the caret across the newline")
}

test "Home and End go to the edges of the visual line" {
  val value = "aaa bbb ccc"
  val lines = Wrap.wrapLines(value, 70.0f32, { s: String -> tenWide(s) })
  val inSecond = Interact.moveCaret(value, Interact.emptyEdit(), 10, false)
  assertEqualInt(
    Interact.moveToLineEdge(value, lines, inSecond, false, false).caret,
    8,
    "Home is the start of the second line"
  )
  assertEqualInt(Interact.moveToLineEdge(value, lines, inSecond, true, false).caret, 11, "End is the end of the text")
  val inFirst = Interact.moveCaret(value, Interact.emptyEdit(), 2, false)
  assertEqualInt(Interact.moveToLineEdge(value, lines, inFirst, true, false).caret, 7, "End of a cut line stays on it")
  assertEqualInt(Interact.moveToLineEdge(value, lines, inFirst, false, true).anchor, 2, "Shift keeps the anchor")
}
