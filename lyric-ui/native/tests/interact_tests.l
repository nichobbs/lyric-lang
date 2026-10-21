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

test "caret placement by pixel picks the nearest boundary" {
  val width = { t: String -> t.length.toFloat() * 8.0f32 }
  assertEqualInt(Interact.caretAt("hello", 0.0f32, width), 0, "left edge")
  assertEqualInt(Interact.caretAt("hello", 21.0f32, width), 3, "nearest the boundary after l")
  assertEqualInt(Interact.caretAt("hello", 500.0f32, width), 5, "past the end")
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
