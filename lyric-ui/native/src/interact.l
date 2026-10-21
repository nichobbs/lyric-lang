//! interact.l - Ui.Native.Interact: what the user can do to a laid-acc tree (docs/67 G10).
//!
//! Pure logic for the native host, so it is tested without a window: the focus order and Tab
//! navigation, hit testing (a dialog is modal: nothing outside it can be hit), text editing with
//! a caret and selection (by code point, so a character is never split), a data grid's scroll
//! range and the viewport it must report, and how a click on each kind of widget turns into a
//! protocol event name and data.  The host (`Ui.Native.Run`) keeps the state between frames and
//! sends the events.
@pure
package Ui.Native.Interact

import Std.Core
import Std.Collections
import Std.String
import Std.Encoding.{codepointToString}
import Std.Parse.{parseOptInt}
import Ui.Core.{Prop}
import Ui.Native.Layout.{Box, Metrics, propOf, gridColumns}

// ─── Focus ────────────────────────────────────────────────────────────────────
/// The boxes Tab visits, in tree order.
pub func focusOrder(page: in Box): List[Box] {
  val acc: List[Box] = newList()
  collectFocusable(page, acc)
  acc
}

func collectFocusable(b: Box, acc: List[Box]): Unit {
  if b.focusable {
    acc.add(b)
  }
  for c in b.children {
    collectFocusable(c, acc)
  }
}

/// The box after (or before) `current` in the focus order, wrapping; the first (or last) when
/// nothing is focused.  `None` when nothing can take focus.
pub func nextFocus(order: in List[Box], current: in String, idOf: in (Box) -> String, backward: in Bool): Option[Box] {
  if order.count == 0 {
    return None
  }
  var at = -1
  var i = 0
  while i < order.count {
    if current.length > 0 and idOf(order[i]) == current {
      at = i
    }
    i = i + 1
  }
  if at < 0 {
    return Some(value = if backward { order[order.count - 1] } else { order[0] })
  }
  val n = if backward { (at + order.count - 1) % order.count } else { (at + 1) % order.count }
  Some(value = order[n])
}

// ─── Hit testing ──────────────────────────────────────────────────────────────
func contains(b: Box, x: Float, y: Float): Bool {
  x >= b.x and x < b.x + b.w and y >= b.y and y < b.y + b.h
}

func interactive(b: Box): Bool {
  b.focusable or ((b.kind == "tableRow" or b.kind == "gridRow") and hasEvent(b, "click")) or b.kind == "dialog"
}

/// Whether the event list of `b` includes `name`.
pub func hasEvent(b: in Box, name: in String): Bool {
  for e in b.events {
    if e == name {
      return true
    }
  }
  false
}

func findDialog(b: Box): Option[Box] {
  if b.kind == "dialog" {
    return Some(value = b)
  }
  for c in b.children {
    match findDialog(c) {
      case Some(d) -> return Some(value = d)
      case None -> ()
    }
  }
  None
}

/// The innermost interactive box under (`x`, `y`).  While a dialog is open only the dialog is
/// searched, and a click on its backdrop hits the dialog box itself.  Rows of a data grid are
/// only hit inside the grid's body.
pub func hitTest(page: in Box, x: in Float, y: in Float): Option[Box] {
  match findDialog(page) {
    case Some(d) -> hitIn(d, x, y)
    case None -> hitIn(page, x, y)
  }
}

func hitIn(b: Box, x: Float, y: Float): Option[Box] {
  if b.kind != "page" and not contains(b, x, y) {
    return None
  }
  var i = b.children.count - 1
  while i >= 0 {
    val c = b.children[i]
    val clipped = (b.kind == "gridBody") and not contains(b, x, y)
    if not clipped {
      match hitIn(c, x, y) {
        case Some(h) -> return Some(value = h)
        case None -> ()
      }
    }
    i = i - 1
  }
  if interactive(b) {
    Some(value = b)
  } else {
    None
  }
}

/// The boxes from the page down to the box for the node at `path` (inclusive), or empty when
/// no box has it.  Helper boxes that share a node's path (a card's title, a grid's body) are
/// never the node's own box.
pub func ancestorsOf(page: in Box, path: in List[Int]): List[Box] {
  match chainTo(page, path) {
    case Some(chain) -> chain
    case None -> newList()
  }
}

func samePath(a: List[Int], b: List[Int]): Bool {
  if a.count != b.count {
    return false
  }
  var i = 0
  while i < a.count {
    if a[i] != b[i] {
      return false
    }
    i = i + 1
  }
  true
}

func helperBox(kind: String): Bool {
  kind == "page" or kind == "colheader" or kind == "gridBody" or kind == "cardTitle" or kind == "fieldLabel" or
    kind == "cardBody" or
    kind == "fieldBody" or
    kind == "dialogPanel" or
    kind == "dialogBody"
}

func chainTo(b: Box, path: List[Int]): Option[List[Box]] {
  if not helperBox(b.kind) and samePath(b.path, path) {
    val chain: List[Box] = newList()
    chain.add(b)
    return Some(value = chain)
  }
  for c in b.children {
    match chainTo(c, path) {
      case Some(rest) -> {
        val chain: List[Box] = newList()
        chain.add(b)
        for r in rest {
          chain.add(r)
        }
        return Some(value = chain)
      }
      case None -> ()
    }
  }
  None
}

// ─── Text editing ─────────────────────────────────────────────────────────────
/// A caret and the other stop of the selection (equal to the caret when nothing is selected), in
/// code points, and the horizontal scroll of a single-line input.
pub record TextEdit {
  caret: Int
  anchor: Int
  scrollX: Float
}

pub func emptyEdit(): TextEdit {
  TextEdit(caret = 0, anchor = 0, scrollX = 0.0f32)
}

pub func cpCount(s: in String): Int {
  codePoints(s).length
}

/// The code points `from ..< to` of `s`.
pub func cpSlice(s: in String, from: in Int, to: in Int): String {
  val cps = codePoints(s)
  val sb = StringBuilder.new()
  var i = if from < 0 { 0 } else { from }
  val stop = if to > cps.length { cps.length } else { to }
  while i < stop {
    StringBuilder.append(sb, codepointToString(cps[i]))
    i = i + 1
  }
  StringBuilder.toString(sb)
}

/// The result of an edit: the new value, the new caret state, and whether the value changed.
pub record Edited {
  value: String
  edit: TextEdit
  changed: Bool
}

func lo(e: TextEdit): Int {
  if e.caret < e.anchor {
    e.caret
  } else {
    e.anchor
  }
}

func hi(e: TextEdit): Int {
  if e.caret < e.anchor {
    e.anchor
  } else {
    e.caret
  }
}

func clampEdit(value: String, e: TextEdit): TextEdit {
  val n = cpCount(value)
  e.copy(
    caret = if e.caret > n { n } else if e.caret < 0 { 0 } else { e.caret },
    anchor = if e.anchor > n { n } else if e.anchor < 0 { 0 } else { e.anchor }
  )
}

/// The selected text.
pub func selectedText(value: in String, e: in TextEdit): String {
  val c = clampEdit(value, e)
  cpSlice(value, lo(c), hi(c))
}

/// `text` typed at the caret, replacing the selection.  `maxLength` (0 for none) bounds the
/// result in code points.
pub func insertText(value: in String, e: in TextEdit, text: in String, maxLength: in Int): Edited {
  val c = clampEdit(value, e)
  var typed = text
  if maxLength > 0 {
    val room = maxLength - (cpCount(value) - (hi(c) - lo(c)))
    if room <= 0 {
      return Edited(value = value, edit = c, changed = false)
    }
    typed = cpSlice(text, 0, room)
  }
  if typed.length == 0 and hi(c) == lo(c) {
    return Edited(value = value, edit = c, changed = false)
  }
  val before = cpSlice(value, 0, lo(c))
  val after = cpSlice(value, hi(c), cpCount(value))
  val caret = lo(c) + cpCount(typed)
  Edited(value = before + typed + after, edit = c.copy(caret = caret, anchor = caret), changed = true)
}

/// Backspace: deletes the selection, or the code point before the caret.
pub func backspace(value: in String, e: in TextEdit): Edited {
  val c = clampEdit(value, e)
  if hi(c) > lo(c) {
    return insertText(value, c, "", 0)
  }
  if c.caret == 0 {
    return Edited(value = value, edit = c, changed = false)
  }
  insertText(value, c.copy(anchor = c.caret - 1), "", 0)
}

/// Delete: deletes the selection, or the code point after the caret.
pub func deleteForward(value: in String, e: in TextEdit): Edited {
  val c = clampEdit(value, e)
  if hi(c) > lo(c) {
    return insertText(value, c, "", 0)
  }
  if c.caret >= cpCount(value) {
    return Edited(value = value, edit = c, changed = false)
  }
  insertText(value, c.copy(anchor = c.caret + 1), "", 0)
}

/// Moves the caret to `position` (clamped); keeps the anchor when `select` extends the selection.
pub func moveCaret(value: in String, e: in TextEdit, position: in Int, select: in Bool): TextEdit {
  val n = cpCount(value)
  val p = if position < 0 { 0 } else if position > n { n } else { position }
  e.copy(caret = p, anchor = if select { e.anchor } else { p })
}

/// Left or right by one code point; with a selection and no `select`, to its edge.
pub func stepCaret(value: in String, e: in TextEdit, delta: in Int, select: in Bool): TextEdit {
  val c = clampEdit(value, e)
  if not select and hi(c) > lo(c) {
    val p = if delta < 0 { lo(c) } else { hi(c) }
    return c.copy(caret = p, anchor = p)
  }
  moveCaret(value, c, c.caret + delta, select)
}

pub func selectAll(value: in String, e: in TextEdit): TextEdit {
  e.copy(anchor = 0, caret = cpCount(value))
}

func isWordPoint(cp: Int): Bool {
  not (cp == 32 or cp == 9 or cp == 10 or cp == 13 or cp == 160 or cp == 12288)
}

/// The selection a double click at code point `position` makes: the run of non-space code points
/// around it (or the run of spaces when it is on one), as an edit with the caret at the end.
pub func wordAt(value: in String, position: in Int): TextEdit {
  val cps = codePoints(value)
  val n = cps.length
  if n == 0 {
    return emptyEdit()
  }
  val at = if position >= n { n - 1 } else if position < 0 { 0 } else { position }
  val word = isWordPoint(cps[at])
  var from = at
  while from > 0 and isWordPoint(cps[from - 1]) == word {
    from = from - 1
  }
  var to = at
  while to < n and isWordPoint(cps[to]) == word {
    to = to + 1
  }
  TextEdit(caret = to, anchor = from, scrollX = 0.0f32)
}

/// The caret position nearest to pixel `x` (relative to the text's left edge).
pub func caretAt(value: in String, x: in Float, widthOf: in (String) -> Float): Int {
  val n = cpCount(value)
  var best = 0
  var bestDist = 1000000.0f32
  var i = 0
  while i <= n {
    val w = widthOf(cpSlice(value, 0, i))
    val d = if w > x { w - x } else { x - w }
    if d < bestDist {
      bestDist = d
      best = i
    }
    i = i + 1
  }
  best
}

// ─── Data grid scrolling ──────────────────────────────────────────────────────
/// `scroll` limited to a body of height `bodyHeight` over `contentHeight` of rows.
pub func clampScroll(scroll: in Float, contentHeight: in Float, bodyHeight: in Float): Float {
  val most = if contentHeight > bodyHeight { contentHeight - bodyHeight } else { 0.0f32 }
  if scroll < 0.0f32 {
    0.0f32
  } else if scroll > most {
    most
  } else {
    scroll
  }
}

func intOf(props: List[Prop], name: String, fallback: Int): Int {
  match parseOptInt(propOf(props, name, "")) {
    case Some(v) -> if v >= 0 { v } else { fallback }
    case None -> fallback
  }
}

/// The `viewport` event data (`"first,count"`) a grid body must report for its `scroll`, or
/// `None` when every visible row is already loaded.  `grid` is the data grid's props.
pub func viewportNeeded(
  gridProps: in List[Prop], loadedRows: in Int, scroll: in Float, bodyHeight: in Float
): Option[String] {
  val rowH = intOf(gridProps, "rowHeight", 36)
  val rowHeight = if rowH > 0 { rowH } else { 36 }
  val total = intOf(gridProps, "rowCount", 0)
  val first = (scroll / rowHeight.toFloat()).toInt()
  val rawCount = (bodyHeight / rowHeight.toFloat()).toInt() + 2
  val count = if rawCount > 1000 { 1000 } else { rawCount }
  val stop = if first + count > total { total } else { first + count }
  if stop <= first {
    return None
  }
  val loaded = intOf(gridProps, "firstRow", 0)
  if first >= loaded and stop <= loaded + loadedRows {
    return None
  }
  Some(value = first.toString() + "," + count.toString())
}

// ─── Clicks ───────────────────────────────────────────────────────────────────
/// A protocol event to send for an interaction.
pub record Action {
  path: List[Int]
  name: String
  data: String
}

/// What a click on `b` does: the events to send, if any.  Inputs, selects and links that are
/// not event sources are handled by the host (focus, popup, navigation).
pub func clickActions(b: in Box): List[Action] {
  val acc: List[Action] = newList()
  if b.kind == "button" or b.kind == "tableRow" or b.kind == "gridRow" {
    if hasEvent(b, "click") {
      acc.add(Action(path = b.path, name = "click", data = ""))
    }
  } else if b.kind == "link" {
    if hasEvent(b, "click") {
      acc.add(Action(path = b.path, name = "click", data = ""))
    }
  } else if b.kind == "checkbox" {
    if hasEvent(b, "change") {
      val now = propOf(b.props, "checked", "") == "true"
      acc.add(Action(path = b.path, name = "change", data = if now { "false" } else { "true" }))
    }
  }
  acc
}
