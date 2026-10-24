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

// Hebrew letters, by code point, so this file has no right to left text in it.
val alef: String = "א"

val bet: String = "ב"

val gimel: String = "ג"

func tenW(): (String) -> Float {
  { s: String -> tenWide(s) }
}

func pieceTexts(value: String, lines: List[Wrap.VisualLine], row: Int): String {
  var r = ""
  var first = true
  for p in Wrap.linePieces(value, lines, row, tenW()) {
    r = r + (if first { "" } else { "|" }) + p.text
    first = false
  }
  r
}

test "text breaks after a hyphen and before an ideograph, never before closing punctuation" {
  assertEqual(joined(lineTexts("well-known fact", 60.0f32)), "well-|known |fact", "after the hyphen")
  assertEqual(joined(lineTexts("漢字仮名漢字", 40.0f32)), "漢字仮名|漢字", "ideographs break anywhere")
  assertEqual(
    joined(lineTexts("漢字仮名、漢", 40.0f32)),
    "漢字仮|名、漢",
    "an ideographic comma is not left at the start of a line"
  )
}

test "a word cut for lack of room keeps a combining mark with its letter" {
  assertEqual(joined(lineTexts("abcd́ef", 40.0f32)), "abcd́|ef", "the mark stays on the first line")
}

test "a right to left paragraph is one piece, aligned to the right of the box" {
  val value = alef + bet + gimel + alef
  val lines = Wrap.wrapLines(value, 100.0f32, tenW())
  assertEqualInt(lines.count, 1, "one line")
  assertTrue(lines[0].rtl, "the paragraph is right to left")
  val pieces = Wrap.linePieces(value, lines, 0, tenW())
  assertEqualInt(pieces.count, 1, "one piece")
  assertEqualInt(pieces[0].level, 1, "an odd level")
  assertTrue(pieces[0].x == 60.0f32, "it ends at the right edge")
  assertTrue(pieces[0].width == 40.0f32, "its width")
  assertTrue(Wrap.offsetInRow(value, lines, 0, 0, tenW()) == 100.0f32, "the start of the text is at the right edge")
  assertTrue(Wrap.offsetInRow(value, lines, 0, 2, tenW()) == 80.0f32, "two letters in")
  assertTrue(Wrap.caretOffset(value, lines, 4, tenW()) == 60.0f32, "the end of the text is at the left of it")
  assertEqualInt(Wrap.positionAt(value, lines, 0, 72.0f32, tenW()), 3, "a click near the left end")
  assertEqualInt(Wrap.positionAt(value, lines, 0, 99.0f32, tenW()), 0, "a click at the right edge")
}

test "a Hebrew word in a Latin line is a piece of its own, in its place on screen" {
  val value = "ab " + alef + bet + gimel + " cd"
  val lines = Wrap.wrapLines(value, 200.0f32, tenW())
  assertFalse(lines[0].rtl, "the paragraph is left to right")
  assertEqual(
    pieceTexts(value, lines, 0),
    "ab|" + alef + bet + gimel + "|cd",
    "three pieces, without the spaces at their ends"
  )
  val pieces = Wrap.linePieces(value, lines, 0, tenW())
  assertTrue(pieces[1].x == 30.0f32 and pieces[1].width == 30.0f32, "the Hebrew word follows ab and a space")
  assertTrue(
    pieces[2].x == 60.0f32 and pieces[2].textX == 70.0f32,
    "a piece's text starts after the space that begins it"
  )
  assertTrue(pieces[0].x == 0.0f32 and pieces[0].textX == 0.0f32, "and a space that ends it is only room")
  assertTrue(Wrap.offsetInRow(value, lines, 0, 3, tenW()) == 30.0f32, "before the word")
  assertTrue(Wrap.offsetInRow(value, lines, 0, 4, tenW()) == 50.0f32, "after its first letter, which is at its right")
  assertTrue(Wrap.offsetInRow(value, lines, 0, 6, tenW()) == 30.0f32, "after the word, at its left end")
  assertTrue(Wrap.offsetInRow(value, lines, 0, 9, tenW()) == 90.0f32, "the end of the line")
  assertEqualInt(Wrap.positionAt(value, lines, 0, 52.0f32, tenW()), 4, "a click between its first two letters")
  assertEqualInt(Wrap.positionAt(value, lines, 0, 31.0f32, tenW()), 3, "a click at the left end of the word")
}

test "a selection across a reversed word is one band for each piece it touches" {
  val value = "ab " + alef + bet + gimel + " cd"
  val lines = Wrap.wrapLines(value, 200.0f32, tenW())
  val bands = Wrap.selectionBands(value, lines, 4, 8, tenW())
  assertEqualInt(bands.count, 2, "two bands")
  assertTrue(bands[0].x0 == 30.0f32 and bands[0].x1 == 50.0f32, "the second and third letters, left of the first")
  assertTrue(bands[1].x0 == 60.0f32 and bands[1].x1 == 80.0f32, "the space and the c")
  val all = Wrap.selectionBands(value, lines, 0, 9, tenW())
  assertEqualInt(all.count, 1, "touching pieces are joined")
  assertTrue(all[0].x0 == 0.0f32 and all[0].x1 == 90.0f32, "the whole line")
}

test "a piece's text is in reading order, for a shaper that is told its direction" {
  val value = alef + "(" + bet + ")"
  val lines = Wrap.wrapLines(value, 100.0f32, tenW())
  assertEqual(pieceTexts(value, lines, 0), value, "the Hebrew and its brackets as typed")
  val neutral = alef + bet + " ab)"
  val nl = Wrap.wrapLines(neutral, 100.0f32, tenW())
  assertEqual(
    pieceTexts(neutral, nl, 0),
    ")|ab|" + alef + bet,
    "a bracket alone is a right to left piece, at the left end"
  )
  val pieces = Wrap.linePieces(neutral, nl, 0, tenW())
  assertEqualInt(pieces[0].level, 1, "the bracket is drawn right to left")
  assertEqualInt(pieces[1].level, 2, "the Latin word is left to right")
  assertEqualInt(pieces[2].level, 1, "the Hebrew word is right to left")
}

test "right to left lines wrap, with the spaces hanging at their left" {
  val word = alef + bet + gimel
  val value = word + " " + word + " " + word
  val lines = Wrap.wrapLines(value, 80.0f32, tenW())
  assertEqualInt(lines.count, 2, "two lines")
  assertTrue(lines[0].rtl and lines[1].rtl, "both right to left")
  assertEqualInt(lines[0].to, 8, "the first line holds two words and a space")
  assertEqualInt(lines[0].visibleTo, 7, "the space hangs")
  assertTrue(Wrap.offsetInRow(value, lines, 0, 0, tenW()) == 80.0f32, "the line starts at the right edge")
  assertTrue(Wrap.offsetInRow(value, lines, 0, 7, tenW()) == 10.0f32, "the end of the words")
  assertTrue(
    Wrap.offsetInRow(value, lines, 0, 8, tenW()) == 0.0f32,
    "the space is the width of a letter, at the left edge"
  )
  val pieces = Wrap.linePieces(value, lines, 1, tenW())
  assertTrue(pieces[0].x == 50.0f32, "the last word is flush right")
  val firstLine = Wrap.linePieces(value, lines, 0, tenW())
  assertTrue(firstLine[0].x == 10.0f32 and firstLine[0].width == 70.0f32, "a line of two words and the space between")
}

test "Left and Right move across a reversed word one letter at a time" {
  val value = "ab " + alef + bet + gimel + " cd"
  val lines = Wrap.wrapLines(value, 200.0f32, tenW())
  assertEqualInt(Wrap.stepVisual(value, lines, 2, 1, tenW()), 3, "right of b: into the space")
  assertEqualInt(
    Wrap.stepVisual(value, lines, 3, 1, tenW()),
    5,
    "right of the space: a letter into the word, from its left end"
  )
  assertEqualInt(Wrap.stepVisual(value, lines, 5, 1, tenW()), 4, "and another")
  assertEqualInt(Wrap.stepVisual(value, lines, 4, -1, tenW()), 5, "Left goes back")
  assertEqualInt(Wrap.stepVisual(value, lines, 5, -1, tenW()), 6, "to the left end of the word, after its last letter")
  assertEqualInt(Wrap.stepVisual(value, lines, 6, -1, tenW()), 2, "and on, out of the word to the left of it")
  assertEqualInt(Wrap.stepVisual(value, lines, 0, -1, tenW()), 0, "Left at the start of the only line")
  assertFalse(Wrap.isMixedAt(Wrap.wrapLines("abc", 200.0f32, tenW()), 1), "plain text is stepped in the text")
  assertTrue(Wrap.isMixedAt(lines, 3), "this line has Hebrew in it")
}

test "Interact steps by screen position in right to left text and by the text elsewhere" {
  val value = alef + bet + gimel
  val lines = Wrap.wrapLines(value, 100.0f32, tenW())
  val start = Interact.moveCaret(value, Interact.emptyEdit(), 0, false)
  assertEqualInt(
    Interact.stepVisualCaret(value, lines, start, 1, false, tenW()).caret,
    0,
    "Right at the right edge stays in the line"
  )
  val inside = Interact.moveCaret(value, Interact.emptyEdit(), 1, false)
  assertEqualInt(
    Interact.stepVisualCaret(value, lines, inside, -1, false, tenW()).caret,
    2,
    "Left moves on through the text"
  )
  assertEqualInt(Interact.stepVisualCaret(value, lines, inside, 1, false, tenW()).caret, 0, "Right moves back")
  val plainLines = Wrap.wrapLines("abc", 100.0f32, tenW())
  val plainStart = Interact.moveCaret("abc", Interact.emptyEdit(), 1, false)
  assertEqualInt(
    Interact.stepVisualCaret("abc", plainLines, plainStart, 1, false, tenW()).caret,
    2,
    "left to right text"
  )
  val selected = Interact.moveCaret(value, Interact.moveCaret(value, Interact.emptyEdit(), 1, false), 3, true)
  assertEqualInt(
    Interact.stepVisualCaret(value, lines, selected, -1, false, tenW()).caret,
    3,
    "Left leaves a selection at its logical end in right to left text"
  )
}

test "the spaces that begin a plain line are room, and its text starts after them" {
  val value = "  abc"
  val lines = Wrap.wrapLines(value, 200.0f32, tenW())
  val pieces = Wrap.linePieces(value, lines, 0, tenW())
  assertEqualInt(pieces.count, 1, "one piece")
  assertEqual(pieces[0].text, "abc", "the text")
  assertTrue(pieces[0].textX == 20.0f32, "after the two spaces")
  assertTrue(Wrap.offsetInRow(value, lines, 0, 2, tenW()) == 20.0f32, "the caret after the spaces")
  assertEqualInt(Wrap.positionAt(value, lines, 0, 24.0f32, tenW()), 2, "a click after them")
}
