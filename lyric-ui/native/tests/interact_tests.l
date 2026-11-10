@test_module
package Ui.Native.InteractTests

import Std.Core
import Std.Collections
import Std.Testing
import Ui.Core.{View, Prop}
import Ui.Diff.{toWire}
import Ui.Widgets
import Ui.Native.Layout.{Box, layoutTree, testEnv}
import Ui.Native.Interact
import Ui.Native.Wrap

union Msg {
  case Hit
  case Typed(s: String)
  case Chose(s: String)
}

func lay(v: View[Msg]): Box {
  layoutTree(toWire(v), testEnv(800.0f32, 600.0f32), 0.0f32)
}

func form(): View[Msg] {
  val kids: List[View[Msg]] = newList()
  val errs: List[String] = newList()
  kids.add(
    Widgets.field("Name", errs, Widgets.textInput("text", "Ada", { s: String -> Typed(s = s) }, Widgets.inputOpts()))
  )
  kids.add(Widgets.checkbox("Subscribe", false, { s: String -> Chose(s = s) }))
  val actions: List[View[Msg]] = newList()
  actions.add(Widgets.button("Cancel", Hit))
  actions.add(Widgets.primaryButton("Save", Hit, false))
  kids.add(Widgets.row(actions))
  Widgets.form(Hit, kids)
}

func boxOr(o: Option[Box], d: Box): Box {
  match o {
    case Some(b) -> b
    case None -> d
  }
}

func idOf(b: Box): String {
  b.kind + ":" + b.text
}

test "focus visits controls in tree order and wraps" {
  val page = lay(form())
  val order = Interact.focusOrder(page)
  assertEqualInt(order.count, 4, "input, checkbox, two buttons")
  assertEqual(order[0].kind, "textInput", "first")
  assertEqual(order[3].text, "Save", "last")
  val first = Interact.nextFocus(order, "", { b: Box -> idOf(b) }, false)
  assertEqual(boxOr(first, order[0]).kind, "textInput", "from nothing: the first")
  val next = Interact.nextFocus(order, idOf(order[1]), { b: Box -> idOf(b) }, false)
  assertEqual(boxOr(next, order[0]).text, "Cancel", "forward")
  val wrapped = Interact.nextFocus(order, idOf(order[3]), { b: Box -> idOf(b) }, false)
  assertEqual(boxOr(wrapped, order[3]).kind, "textInput", "forward wraps")
  val back = Interact.nextFocus(order, idOf(order[0]), { b: Box -> idOf(b) }, true)
  assertEqual(boxOr(back, order[0]).text, "Save", "backward wraps")
  val backFromNothing = Interact.nextFocus(order, "", { b: Box -> idOf(b) }, true)
  assertEqual(boxOr(backFromNothing, order[0]).text, "Save", "backward from nothing: the last")
}

test "hit testing finds the innermost control" {
  val page = lay(form())
  val order = Interact.focusOrder(page)
  val save = order[3]
  val hit = Interact.hitTest(page, save.x + 3.0f32, save.y + 3.0f32)
  assertEqual(boxOr(hit, page).text, "Save", "button")
  assertTrue(Interact.hitTest(page, 2.0f32, 2.0f32).isNone(), "empty space")
}

test "an open dialog is modal" {
  val kids: List[View[Msg]] = newList()
  kids.add(Widgets.button("Behind", Hit))
  val inner: List[View[Msg]] = newList()
  inner.add(Widgets.button("Yes", Hit))
  kids.add(Ui.Widgets.element(Ui.Core.WidgetKind.Dialog, Widgets.noProps(), newList(), inner))
  val page = lay(Widgets.column(kids))
  val behind = page.children[0].children[0]
  val hitBehind = Interact.hitTest(page, behind.x + 3.0f32, behind.y + 3.0f32)
  assertEqual(boxOr(hitBehind, page).kind, "dialog", "a click behind the dialog hits the backdrop")
  val dialog = page.children[0].children[1]
  val yes = dialog.children[0].children[0].children[0]
  assertEqual(yes.text, "Yes", "the dialog's button")
  val hitYes = Interact.hitTest(page, yes.x + 3.0f32, yes.y + 3.0f32)
  assertEqual(boxOr(hitYes, page).text, "Yes", "inside the dialog")
}

test "typing replaces the selection and moves the caret" {
  var e = Interact.emptyEdit()
  var r = Interact.insertText("", e, "héllo", 0)
  assertEqual(r.value, "héllo", "typed")
  assertEqualInt(r.edit.caret, 5, "caret after the text")
  e = Interact.selectAll(r.value, r.edit)
  r = Interact.insertText(r.value, e, "x", 0)
  assertEqual(r.value, "x", "selection replaced")
  r = Interact.insertText("abc", Interact.moveCaret("abc", Interact.emptyEdit(), 1, false), "ZZ", 0)
  assertEqual(r.value, "aZZbc", "inserted at the caret")
}

test "backspace and delete work on selections and single characters" {
  val e = Interact.moveCaret("abc", Interact.emptyEdit(), 2, false)
  val b = Interact.backspace("abc", e)
  assertEqual(b.value, "ac", "backspace")
  assertEqualInt(b.edit.caret, 1, "caret back")
  val d = Interact.deleteForward("abc", e)
  assertEqual(d.value, "ab", "delete")
  val none = Interact.backspace("abc", Interact.emptyEdit())
  assertTrue(not none.changed, "backspace at the start does nothing")
  val sel = Interact.moveCaret("abcd", Interact.moveCaret("abcd", Interact.emptyEdit(), 1, false), 3, true)
  assertEqual(Interact.selectedText("abcd", sel), "bc", "selection")
  assertEqual(Interact.backspace("abcd", sel).value, "ad", "backspace deletes the selection")
}

test "max length truncates typed text and refuses when full" {
  val r = Interact.insertText("ab", Interact.moveCaret("ab", Interact.emptyEdit(), 2, false), "cdef", 4)
  assertEqual(r.value, "abcd", "truncated")
  val full = Interact.insertText("abcd", Interact.moveCaret("abcd", Interact.emptyEdit(), 4, false), "x", 4)
  assertTrue(not full.changed, "full")
}

test "text editing counts code points, not UTF-16 units" {
  val s = "a😀b"
  assertEqualInt(Interact.cpCount(s), 3, "three code points")
  val e = Interact.moveCaret(s, Interact.emptyEdit(), 2, false)
  val b = Interact.backspace(s, e)
  assertEqual(b.value, "ab", "the emoji is deleted whole")
}

test "caret placement by pixel in a single-line input picks the nearest boundary" {
  val width = { t: String -> t.length.toFloat() * 8.0f32 }
  val lines = Wrap.singleLine("hello", 100.0f32, width)
  assertEqualInt(Wrap.positionAt("hello", lines, 0, 0.0f32, width), 0, "left edge")
  assertEqualInt(Wrap.positionAt("hello", lines, 0, 21.0f32, width), 3, "nearest the boundary after l")
  assertEqualInt(Wrap.positionAt("hello", lines, 0, 500.0f32, width), 5, "past the end")
}

test "grid scroll is clamped to the rows and the viewport it needs is reported" {
  assertTrue(Interact.clampScroll(-5.0f32, 3600.0f32, 360.0f32) == 0.0f32, "not above the top")
  assertTrue(Interact.clampScroll(99999.0f32, 3600.0f32, 360.0f32) == 3240.0f32, "not past the end")
  assertTrue(Interact.clampScroll(10.0f32, 100.0f32, 360.0f32) == 0.0f32, "short content does not scroll")
  val props: List[Prop] = [
    Prop(name = "rowCount", value = "100"),
    Prop(name = "firstRow", value = "0"),
    Prop(name = "rowHeight", value = "36")
  ]
  assertTrue(Interact.viewportNeeded(props, 12, 0.0f32, 360.0f32).isNone(), "the loaded rows cover the top")
  match Interact.viewportNeeded(props, 12, 720.0f32, 360.0f32) {
    case Some(d) -> assertEqual(d, "20,12", "rows 20 on")
    case None -> assertTrue(false, "needs rows 20 onward")
  }
}

test "a click on a button sends click and on a checkbox sends the flipped value" {
  val page = lay(form())
  val order = Interact.focusOrder(page)
  val acts = Interact.clickActions(order[3])
  assertEqualInt(acts.count, 1, "one event")
  assertEqual(acts[0].name, "click", "click")
  val box = Interact.clickActions(order[1])
  assertEqual(box[0].name, "change", "change")
  assertEqual(box[0].data, "true", "unchecked becomes checked")
  assertEqualInt(Interact.clickActions(order[0]).count, 0, "inputs only take focus")
}

test "ancestors lead from the page to a node" {
  val page = lay(form())
  val order = Interact.focusOrder(page)
  val chain = Interact.ancestorsOf(page, order[3].path)
  assertTrue(chain.count >= 3, "page, form, row, button")
  assertEqual(chain[0].kind, "page", "starts at the page")
  assertEqual(chain[chain.count - 1].text, "Save", "ends at the node")
  var form = false
  for b in chain {
    if b.kind == "form" {
      form = true
    }
  }
  assertTrue(form, "the form is on the way")
}

test "a double click selects the word under it" {
  val e = Interact.wordAt("hello big world", 7)
  assertEqual(Interact.selectedText("hello big world", e), "big", "the middle word")
  val first = Interact.wordAt("hello big world", 0)
  assertEqual(Interact.selectedText("hello big world", first), "hello", "the first word")
  val gap = Interact.wordAt("a  b", 1)
  assertEqual(Interact.selectedText("a  b", gap), "  ", "a run of spaces")
  val last = Interact.wordAt("end", 99)
  assertEqual(Interact.selectedText("end", last), "end", "past the end selects the last word")
  assertEqualInt(Interact.cpCount(Interact.selectedText("", Interact.wordAt("", 0))), 0, "empty text")
}

test "a double click selects a word without the punctuation next to it" {
  val v = "hello, world. can't"
  assertEqual(Interact.selectedText(v, Interact.wordAt(v, 2)), "hello", "the comma is not part of the word")
  assertEqual(Interact.selectedText(v, Interact.wordAt(v, 5)), ",", "a click on the comma selects it")
  assertEqual(Interact.selectedText(v, Interact.wordAt(v, 16)), "can't", "an apostrophe inside a word is")
  assertEqual(Interact.selectedText("漢字", Interact.wordAt("漢字", 1)), "字", "one ideograph")
}

test "Ctrl+Left and Ctrl+Right move by word, in the direction the paragraph reads" {
  val v = "one two, three"
  val start = Interact.moveCaret(v, Interact.emptyEdit(), 0, false)
  val r1 = Interact.moveWord(v, start, 1, false, false)
  assertEqualInt(r1.caret, 3, "to the end of one")
  val r2 = Interact.moveWord(v, r1, 1, false, false)
  assertEqualInt(r2.caret, 7, "to the end of two, before the comma")
  val l1 = Interact.moveWord(v, r2, -1, false, false)
  assertEqualInt(l1.caret, 4, "back to the start of two")
  val selected = Interact.moveWord(v, start, 1, false, true)
  assertEqualInt(selected.anchor, 0, "with Shift the selection grows")
  assertEqualInt(selected.caret, 3, "to the word's end")
  val rtl = Interact.moveWord(v, start, -1, true, false)
  assertEqualInt(rtl.caret, 3, "in a right to left paragraph Left goes forward in the text")
}

func inputOf(kind: String, value: String): Box {
  val kids: List[View[Msg]] = newList()
  kids.add(Widgets.textInput(kind, value, { s: String -> Typed(s = s) }, Widgets.inputOpts()))
  val order = Interact.focusOrder(lay(Widgets.column(kids)))
  order[0]
}

test "a password shows one bullet per code point and nothing of its value" {
  val pw = inputOf("password", "pässwörd 1")
  assertTrue(Interact.isMasked(pw), "a password is masked")
  val shown = Interact.shownValue(pw, pw.text)
  assertEqualInt(Interact.cpCount(shown), Interact.cpCount(pw.text), "the same caret positions")
  assertEqual(shown, "••••••••••", "only bullets")
  assertEqual(Interact.shownValue(pw, ""), "", "an empty password draws nothing")
  val email = inputOf("email", "a@b.c")
  assertFalse(Interact.isMasked(email), "other inputs are not")
  assertEqual(Interact.shownValue(email, email.text), "a@b.c", "and draw their value")
}

func tenWide(s: String): Float {
  Interact.cpCount(s).toFloat() * 10.0f32
}

func caretScroll(value: String, caret: Int, scroll: Float, view: Float): Float {
  val w = { s: String -> tenWide(s) }
  val lines = Wrap.singleLine(value, view, w)
  val edges = Wrap.lineEdgesOf(value, lines, 0, w)
  val cx = Wrap.offsetInRowAt(value, lines, 0, caret, false, w)
  Interact.scrollToCaretX(scroll, cx, edges[0], edges[1], view, 8.0f32)
}

test "a single-line input scrolls to keep the caret in view, never past the text (#8813)" {
  // 20 characters of 10 px in a 100 px box.
  val v = "abcdefghijklmnopqrst"
  assertTrue(caretScroll(v, 3, 0.0f32, 100.0f32) == 0.0f32, "a caret inside the box leaves the scroll alone")
  assertTrue(caretScroll(v, 20, 0.0f32, 100.0f32) == 100.0f32, "the end of the text scrolls to its last pixel")
  assertTrue(caretScroll(v, 12, 0.0f32, 100.0f32) == 28.0f32, "a caret past the right edge ends 8 px inside it")
  assertTrue(caretScroll(v, 2, 100.0f32, 100.0f32) == 12.0f32, "a caret before the left edge ends 8 px inside it")
  assertTrue(caretScroll(v, 0, 60.0f32, 100.0f32) == 0.0f32, "the start is never scrolled past")
  assertTrue(caretScroll("abcde", 5, 40.0f32, 100.0f32) == 0.0f32, "text that fits is not scrolled")
}

test "a right to left value wider than the box scrolls over its visual extent (#8813)" {
  val v = "אבגדהוזחטיךכ"
  // Twelve characters, 120 px, in a 100 px box: laid out from the left edge, caret 0 at the right end.
  assertTrue(caretScroll(v, 0, 0.0f32, 100.0f32) == 20.0f32, "the logical start is at the right end")
  assertTrue(caretScroll(v, 12, 20.0f32, 100.0f32) == 0.0f32, "the logical end is at the left end")
  assertTrue(caretScroll("אבג", 0, 30.0f32, 100.0f32) == 0.0f32, "a value that fits is not scrolled")
}

test "a mixed value scrolls to the caret's visual place (#8813)" {
  // Latin, a Hebrew word, Latin: 21 characters, 210 px, in a 100 px box.
  val v = "abcdefghijאבגדklmnopq"
  assertTrue(caretScroll(v, 0, 50.0f32, 100.0f32) == 0.0f32, "the start of the line")
  assertTrue(caretScroll(v, 21, 0.0f32, 100.0f32) == 110.0f32, "the end of the line")
}
