//! layout.l - Ui.Native.Layout: flex-style layout of a widget tree (docs/65 §13.3, docs/67 G10).
//!
//! `layoutTree` turns the host's mirror of the session's tree (a `WireNode`) into a tree of
//! `Box`es with absolute rectangles, for the painter to draw and for hit testing.  It is pure: text
//! is measured through a `Metrics` the host supplies (the real one asks `lyric-text`; tests use
//! `fixedMetrics`), and a data grid's scroll offset comes from the caller, so the same tree and
//! the same inputs always give the same boxes.
//!
//! The rules follow `runtime/ui.css`: columns stack and stretch their children with a gap, rows
//! flow left to right and wrap, a spacer takes the rest of a row, cards and sections have padding
//! and a border, a field is a label above its control and errors, tables size columns to their
//! content, a data grid has a header and a scrolling body, and a dialog is an overlay over the
//! whole window.  The page is centred in at most `pageMaxWidth` with the page padding around it.
//!
//! Widgets whose content is text (headings, buttons, links, labels, cells) hold it in `Box.text`
//! and have no child boxes; a box's `path` is the child-index path of its node from the root, so
//! an event can be addressed to it (`Ui.Native.Client.eventPath`).
@pure
package Ui.Native.Layout

import Std.Core
import Std.Collections
import Std.String
import Std.Parse.{parseOptInt}
import Std.JsonValue.{JsonValue, JArray, JObject, parseValue, getString, getArray, asString}
import Ui.Core.{Prop}
import Ui.Diff.{WireNode, WElement, WText, WEmpty}
import Ui.Native.Theme.{Theme, styleBody, styleBold, styleSmall, styleH1, styleH2, styleH3}
import Ui.Native.Wrap

pub record Size {
  w: Float
  h: Float
}

/// How the host measures text: `measure(text, style, maxWidth)` is the size of `text` set in a
/// style and wrapped to `maxWidth` pixels (no wrapping when it is not positive); `lineHeight` is
/// one line of a style.
pub record Metrics {
  measure: (String, Int, Float) -> Size
  lineHeight: (Int) -> Float
}

/// Everything layout needs besides the tree.
pub record Env {
  theme: Theme
  metrics: Metrics
  windowWidth: Float
  windowHeight: Float
  /// The scroll offset of the data grid at a path, in pixels.
  gridScroll: (List[Int]) -> Float
}

pub record Box {
  kind: String
  path: List[Int]
  key: String
  props: List[Prop]
  events: List[String]
  text: String
  style: Int
  x: Float
  y: Float
  w: Float
  h: Float
  children: List[Box]
  focusable: Bool
  /// A data grid's total body height (the scroll range), else 0.
  contentHeight: Float
}

/// Layout of the whole tree: the page box (kind `page`), its children the app's boxes, with any
/// dialogs placed over the window.  `contentHeight` of the page is the height the content needs.
pub func layoutTree(root: in WireNode, env: in Env, pageScroll: in Float): Box {
  val t = env.theme
  val avail = if env.windowWidth < t.pageMaxWidth { env.windowWidth } else { t.pageMaxWidth }
  val x = (env.windowWidth - avail) / 2.0f32 + 16.0f32
  val w = avail - 32.0f32
  val y = t.pagePadding - pageScroll
  val path: List[Int] = newList()
  val b = layoutNode(root, path, x, y, w, env)
  Box(
    kind = "page",
    path = path,
    key = "",
    props = newList(),
    events = newList(),
    text = "",
    style = styleBody,
    x = 0.0f32,
    y = 0.0f32,
    w = env.windowWidth,
    h = env.windowHeight,
    children = [b],
    focusable = false,
    contentHeight = b.h + t.pagePadding * 2.0f32
  )
}

// ─── Helpers ──────────────────────────────────────────────────────────────────
pub func propOf(props: in List[Prop], name: in String, fallback: in String): String {
  for p in props {
    if p.name == name {
      return p.value
    }
  }
  fallback
}

func flag(props: List[Prop], name: String): Bool {
  propOf(props, name, "") == "true"
}

/// The text a node shows: a text node's value, or the concatenated text of its descendants.
pub func textOfWire(n: in WireNode): String {
  match n {
    case WText(v) -> v
    case WEmpty -> ""
    case WElement(_, _, _, _, children) -> {
      var s = ""
      for c in children {
        s = s + textOfWire(c)
      }
      s
    }
  }
}

func childPath(path: List[Int], i: Int): List[Int] {
  val p: List[Int] = newList()
  for x in path {
    p.add(x)
  }
  p.add(i)
  p
}

func maxF(a: Float, b: Float): Float {
  if a > b {
    a
  } else {
    b
  }
}

func minF(a: Float, b: Float): Float {
  if a < b {
    a
  } else {
    b
  }
}

func textBox(
  kind: String,
  path: List[Int],
  key: String,
  props: List[Prop],
  events: List[String],
  text: String,
  style: Int,
  x: Float,
  y: Float,
  w: Float,
  h: Float,
  focusable: Bool,
): Box {
  Box(
    kind = kind,
    path = path,
    key = key,
    props = props,
    events = events,
    text = text,
    style = style,
    x = x,
    y = y,
    w = w,
    h = h,
    children = newList(),
    focusable = focusable,
    contentHeight = 0.0f32
  )
}

func containerBox(
  kind: String,
  path: List[Int],
  key: String,
  props: List[Prop],
  events: List[String],
  x: Float,
  y: Float,
  w: Float,
  h: Float,
  children: List[Box],
): Box {
  Box(
    kind = kind,
    path = path,
    key = key,
    props = props,
    events = events,
    text = "",
    style = styleBody,
    x = x,
    y = y,
    w = w,
    h = h,
    children = children,
    focusable = false,
    contentHeight = 0.0f32
  )
}

func isOverlay(n: WireNode): Bool {
  match n {
    case WElement(kind, _, _, _, _) -> kind == "dialog"
    case _ -> false
  }
}

func isSpacer(n: WireNode): Bool {
  match n {
    case WElement(kind, _, _, _, _) -> kind == "spacer"
    case _ -> false
  }
}

func headingStyle(props: List[Prop]): Int {
  val level = match parseOptInt(propOf(props, "level", "1")) { case Some(n) -> n; case None -> 1 }
  if level <= 1 {
    styleH1
  } else if level == 2 {
    styleH2
  } else {
    styleH3
  }
}

/// The least and the most a text area is tall: it grows with its wrapped lines between them and
/// scrolls beyond the most.
pub val textAreaMinHeight: Float = 88.0f32

pub val textAreaMaxHeight: Float = 264.0f32

/// The padding above and below a text area's lines.
pub val textAreaPadding: Float = 7.0f32

/// The wrapped lines of a text area `w` wide showing `value`.
pub func textAreaLines(value: in String, w: in Float, env: in Env): List[Wrap.VisualLine] {
  val m = env.metrics
  Wrap.wrapLines(value, w - 2.0f32 * env.theme.inputPadding, { s: String -> m.measure(s, styleBody, 0.0f32).w })
}

/// The height of a text area `w` wide showing `value`.
pub func textAreaHeight(value: in String, w: in Float, env: in Env): Float {
  val lines = textAreaLines(value, w, env)
  val content = Wrap.contentHeight(lines, env.metrics.lineHeight(styleBody)) + 2.0f32 * textAreaPadding
  if content < textAreaMinHeight {
    textAreaMinHeight
  } else if content > textAreaMaxHeight {
    textAreaMaxHeight
  } else {
    content
  }
}

// ─── Natural widths (max-content), for rows and tables ────────────────────────
/// The width `n` takes when nothing constrains it.
pub func naturalWidth(n: in WireNode, env: in Env): Float {
  val m = env.metrics
  val t = env.theme
  match n {
    case WText(v) -> m.measure(v, styleBody, 0.0f32).w
    case WEmpty -> 0.0f32
    case WElement(kind, _, props, _, children) -> {
      if kind == "button" {
        m.measure(propOf(props, "label", ""), styleBold, 0.0f32).w + 30.0f32
      } else if kind == "link" or kind == "label" {
        m.measure(textOfWire(n), styleBody, 0.0f32).w
      } else if kind == "badge" {
        m.measure(textOfWire(n), styleSmall, 0.0f32).w + 18.0f32
      } else if kind == "heading" {
        m.measure(textOfWire(n), headingStyle(props), 0.0f32).w
      } else if kind == "paragraph" {
        m.measure(textOfWire(n), styleBody, 0.0f32).w
      } else if kind == "checkbox" {
        m.measure(propOf(props, "label", ""), styleBody, 0.0f32).w + 26.0f32
      } else if kind == "spinner" {
        24.0f32
      } else if kind == "spacer" {
        0.0f32
      } else if kind == "textInput" or kind == "numberInput" or kind == "dateInput" or kind == "select" {
        220.0f32
      } else if kind == "textArea" {
        320.0f32
      } else if kind == "row" {
        var total = 0.0f32
        var count = 0
        for c in children {
          if not isOverlay(c) {
            total = total + naturalWidth(c, env)
            count = count + 1
          }
        }
        total + t.gap * (if count > 1 { (count - 1).toFloat() } else { 0.0f32 })
      } else {
        var widest = 0.0f32
        for c in children {
          widest = maxF(widest, naturalWidth(c, env))
        }
        if kind == "card" or kind == "section" {
          widest + 34.0f32
        } else {
          widest
        }
      }
    }
  }
}

// ─── The layout pass ──────────────────────────────────────────────────────────
/// Lays `n` acc at (`x`, `y`) in an available width `w`.
pub func layoutNode(n: in WireNode, path: in List[Int], x: in Float, y: in Float, w: in Float, env: in Env): Box {
  val t = env.theme
  val m = env.metrics
  match n {
    case WText(v) -> {
      val s = m.measure(v, styleBody, w)
      textBox("text", path, "", newList(), newList(), v, styleBody, x, y, w, s.h, false)
    }
    case WEmpty -> textBox("empty", path, "", newList(), newList(), "", styleBody, x, y, 0.0f32, 0.0f32, false)
    case WElement(kind, key, props, events, children) -> {
      if kind == "column" or kind == "form" {
        stackBox(kind, n, path, key, props, events, x, y, w, t.gap, 0.0f32, env)
      } else if kind == "row" {
        rowBox(n, path, key, props, events, x, y, w, env)
      } else if kind == "card" or kind == "section" {
        cardBox(n, path, key, props, events, x, y, w, env)
      } else if kind == "spacer" {
        textBox("spacer", path, key, props, events, "", styleBody, x, y, w, 0.0f32, false)
      } else if kind == "heading" {
        val st = headingStyle(props)
        val txt = textOfWire(n)
        textBox("heading", path, key, props, events, txt, st, x, y, w, m.measure(txt, st, w).h, false)
      } else if kind == "paragraph" {
        val txt = textOfWire(n)
        textBox("paragraph", path, key, props, events, txt, styleBody, x, y, w, m.measure(txt, styleBody, w).h, false)
      } else if kind == "label" {
        val txt = textOfWire(n)
        val s = m.measure(txt, styleBody, 0.0f32)
        textBox("label", path, key, props, events, txt, styleBody, x, y, s.w, s.h, false)
      } else if kind == "badge" {
        val txt = textOfWire(n)
        val s = m.measure(txt, styleSmall, 0.0f32)
        textBox("badge", path, key, props, events, txt, styleSmall, x, y, s.w + 18.0f32, s.h + 4.0f32, false)
      } else if kind == "banner" {
        val txt = textOfWire(n)
        val s = m.measure(txt, styleBody, w - 28.0f32)
        textBox("banner", path, key, props, events, txt, styleBody, x, y, w, s.h + 20.0f32, false)
      } else if kind == "spinner" {
        textBox("spinner", path, key, props, events, "", styleBody, x, y, 24.0f32, 24.0f32, false)
      } else if kind == "fieldError" {
        val txt = textOfWire(n)
        textBox("fieldError", path, key, props, events, txt, styleSmall, x, y, w, m.measure(txt, styleSmall, w).h, false)
      } else if kind == "field" {
        fieldBox(n, path, key, props, events, x, y, w, env)
      } else if kind == "textInput" or kind == "numberInput" or kind == "dateInput" {
        textBox(
          kind,
          path,
          key,
          props,
          events,
          propOf(props, "value", ""),
          styleBody,
          x,
          y,
          w,
          t.controlHeight,
          not flag(props, "disabled")
        )
      } else if kind == "textArea" {
        val value = propOf(props, "value", "")
        textBox(
          kind,
          path,
          key,
          props,
          events,
          value,
          styleBody,
          x,
          y,
          w,
          textAreaHeight(value, w, env),
          not flag(props, "disabled")
        )
      } else if kind == "checkbox" {
        val label = propOf(props, "label", "")
        val s = m.measure(label, styleBody, 0.0f32)
        textBox(
          "checkbox",
          path,
          key,
          props,
          events,
          label,
          styleBody,
          x,
          y,
          s.w + 26.0f32,
          maxF(18.0f32, s.h),
          not flag(props, "disabled")
        )
      } else if kind == "select" {
        textBox(
          "select",
          path,
          key,
          props,
          events,
          selectedLabel(n),
          styleBody,
          x,
          y,
          w,
          t.controlHeight,
          not flag(props, "disabled")
        )
      } else if kind == "button" {
        val label = propOf(props, "label", "")
        val s = m.measure(label, styleBold, 0.0f32)
        val blocked = flag(props, "disabled") or flag(props, "busy")
        textBox("button", path, key, props, events, label, styleBold, x, y, s.w + 30.0f32, t.controlHeight, not blocked)
      } else if kind == "link" {
        val txt = textOfWire(n)
        val s = m.measure(txt, styleBody, 0.0f32)
        textBox("link", path, key, props, events, txt, styleBody, x, y, s.w, s.h, true)
      } else if kind == "table" {
        tableBox(n, path, key, props, events, x, y, w, env)
      } else if kind == "dataGrid" {
        gridBox(n, path, key, props, events, x, y, w, env)
      } else if kind == "dialog" {
        dialogBox(n, path, key, props, events, env)
      } else if kind == "option" or kind == "toast" {
        textBox(kind, path, key, props, events, textOfWire(n), styleBody, x, y, 0.0f32, 0.0f32, false)
      } else if kind == "tableRow" or kind == "gridRow" or kind == "tableCell" or kind == "gridCell" {
        stackBox(kind, n, path, key, props, events, x, y, w, 0.0f32, 0.0f32, env)
      } else {
        val txt = "Unsupported widget: " + kind
        textBox("label", path, key, props, events, txt, styleBody, x, y, w, m.measure(txt, styleBody, w).h, false)
      }
    }
  }
}

func selectedLabel(n: WireNode): String {
  match n {
    case WElement(_, _, props, _, children) -> {
      val current = propOf(props, "value", "")
      for c in children {
        match c {
          case WElement(kind, _, cp, _, _) -> if kind == "option" and propOf(cp, "value", "") == current {
            return textOfWire(c)
          }
          case _ -> ()
        }
      }
      current
    }
    case _ -> ""
  }
}

// A vertical stack: children stretched to `w` (controls that size to their content keep their
// own width), `gap` between them, `pad` inside.
func stackBox(
  kind: String,
  n: WireNode,
  path: List[Int],
  key: String,
  props: List[Prop],
  events: List[String],
  x: Float,
  y: Float,
  w: Float,
  gap: Float,
  pad: Float,
  env: Env,
): Box {
  val kids: List[Box] = newList()
  var cy = y + pad
  var first = true
  var i = 0
  for c in childrenOf(n) {
    val probeY = if first { cy } else { cy + gap }
    val b = layoutNode(c, childPath(path, i), x + pad, probeY, w - pad * 2.0f32, env)
    kids.add(b)
    if not isOverlay(c) and (b.h > 0.0f32 or not isSpacer(c)) {
      cy = probeY + b.h
      first = false
    }
    i = i + 1
  }
  containerBox(kind, path, key, props, events, x, y, w, cy - y + pad, kids)
}

func childrenOf(n: WireNode): List[WireNode] {
  match n {
    case WElement(_, _, _, _, children) -> children
    case _ -> newList()
  }
}

// A flow row: children at their natural widths, left to right, wrapping, a spacer taking the
// rest of its line, items centred vertically in their line.
func rowBox(
  n: WireNode,
  path: List[Int],
  key: String,
  props: List[Prop],
  events: List[String],
  x: Float,
  y: Float,
  w: Float,
  env: Env,
): Box {
  val t = env.theme
  val kids = childrenOf(n)
  val boxes: List[Box] = newList()
  var lineStart = 0
  var lineX = x
  var lineY = y
  var lineH = 0.0f32
  var totalH = 0.0f32
  var i = 0
  var onLine: List[Int] = newList()
  // First pass: place at natural widths, breaking lines.
  while i < kids.count {
    val c = kids[i]
    if isOverlay(c) {
      boxes.add(layoutNode(c, childPath(path, i), x, y, w, env))
    } else {
      val nw = minF(naturalWidth(c, env), w)
      val b = layoutNode(c, childPath(path, i), lineX, lineY, nw, env)
      val bw = if isSpacer(c) { 0.0f32 } else { b.w }
      if lineX > x and lineX + bw > x + w + 0.5f32 {
        lineY = lineY + lineH + t.gap
        totalH = totalH + lineH + t.gap
        lineH = 0.0f32
        lineX = x
        onLine = newList()
        boxes.add(layoutNode(c, childPath(path, i), lineX, lineY, nw, env))
      } else {
        boxes.add(b)
      }
      val placed = boxes[boxes.count - 1]
      lineH = maxF(lineH, placed.h)
      lineX = lineX + (if isSpacer(c) { 0.0f32 } else { placed.w }) + t.gap
      onLine.add(boxes.count - 1)
    }
    i = i + 1
  }
  totalH = totalH + lineH
  val centred = centreLines(boxes, kids, x, y, w, totalH, t.gap)
  containerBox("row", path, key, props, events, x, y, w, totalH, centred)
}

// Second pass for rows: spacers take the rest of their line, items are centred in the line.
func centreLines(
  boxes: List[Box], kids: List[WireNode], x: Float, y: Float, w: Float, totalH: Float, gap: Float
): List[Box] {
  val acc: List[Box] = newList()
  var i = 0
  var lineTop = y
  while i < boxes.count {
    // Find the line: boxes whose y differs from the first's belong to later lines.
    val first = boxes[i]
    var j = i
    var lineH = 0.0f32
    var spacerAt = -1
    var used = 0.0f32
    var count = 0
    while j < boxes.count and boxes[j].y == first.y {
      lineH = maxF(lineH, boxes[j].h)
      if boxes[j].kind == "spacer" {
        spacerAt = j
      } else if boxes[j].kind != "dialog" {
        used = used + boxes[j].w
        count = count + 1
      }
      j = j + 1
    }
    val free = maxF(
      0.0f32,
      w - used - gap * (if count > 1 { (count - 1).toFloat() } else { 0.0f32 }) -
        (if spacerAt >= 0 { gap } else { 0.0f32 })
    )
    var shift = 0.0f32
    var k = i
    while k < j {
      val b = boxes[k]
      if b.kind == "spacer" {
        acc.add(b.copy(w = free))
        shift = shift + free
      } else {
        val dy = (lineH - b.h) / 2.0f32
        acc.add(moveBox(b, shift, dy))
      }
      k = k + 1
    }
    i = j
  }
  acc
}

/// `b` and everything in it moved by (`dx`, `dy`).
pub func moveBox(b: in Box, dx: in Float, dy: in Float): Box {
  if dx == 0.0f32 and dy == 0.0f32 {
    return b
  }
  val kids: List[Box] = newList()
  for c in b.children {
    kids.add(moveBox(c, dx, dy))
  }
  b.copy(x = b.x + dx, y = b.y + dy, children = kids)
}

func cardBox(
  n: WireNode,
  path: List[Int],
  key: String,
  props: List[Prop],
  events: List[String],
  x: Float,
  y: Float,
  w: Float,
  env: Env,
): Box {
  val t = env.theme
  val kind = match n { case WElement(k, _, _, _, _) -> k; case _ -> "card" }
  val title = propOf(props, "title", "")
  val st = if kind == "card" { styleH2 } else { styleH3 }
  val kids: List[Box] = newList()
  var cy = y + 16.0f32
  if title.length > 0 {
    val th = env.metrics.measure(title, st, w - 34.0f32).h
    kids.add(textBox("cardTitle", path, "", newList(), newList(), title, st, x + 17.0f32, cy, w - 34.0f32, th, false))
    cy = cy + th + 12.0f32
  }
  val body = stackBox("cardBody", n, path, "", newList(), newList(), x + 17.0f32, cy, w - 34.0f32, t.gap, 0.0f32, env)
  kids.add(body)
  cy = cy + body.h
  containerBox(kind, path, key, props, events, x, y, w, cy - y + 17.0f32, kids)
}

func fieldBox(
  n: WireNode,
  path: List[Int],
  key: String,
  props: List[Prop],
  events: List[String],
  x: Float,
  y: Float,
  w: Float,
  env: Env,
): Box {
  val label = propOf(props, "label", "")
  val kids: List[Box] = newList()
  var cy = y
  if label.length > 0 {
    val lh = env.metrics.measure(label, styleBold, w).h
    kids.add(textBox("fieldLabel", path, "", newList(), newList(), label, styleBold, x, cy, w, lh, false))
    cy = cy + lh + 4.0f32
  }
  val body = stackBox("fieldBody", n, path, "", newList(), newList(), x, cy, w, 4.0f32, 0.0f32, env)
  kids.add(body)
  containerBox("field", path, key, props, events, x, y, w, cy + body.h - y, kids)
}

// ─── Tables ───────────────────────────────────────────────────────────────────
func tableBox(
  n: WireNode,
  path: List[Int],
  key: String,
  props: List[Prop],
  events: List[String],
  x: Float,
  y: Float,
  w: Float,
  env: Env,
): Box {
  val rows = childrenOf(n)
  var columns = 0
  for r in rows {
    var cells = 0
    for c in childrenOf(r) {
      cells = cells + 1
    }
    columns = if cells > columns { cells } else { columns }
  }
  val widths: List[Float] = newList()
  var ci = 0
  while ci < columns {
    var widest = 40.0f32
    for r in rows {
      val cs = childrenOf(r)
      if ci < cs.count {
        val st = if flag(propsOfWire(cs[ci]), "header") { styleBold } else { styleBody }
        widest = maxF(widest, env.metrics.measure(textOfWire(cs[ci]), st, 0.0f32).w + 20.0f32)
      }
    }
    widths.add(widest)
    ci = ci + 1
  }
  var sum = 0.0f32
  for cw in widths {
    sum = sum + cw
  }
  val scale = if sum > 0.0f32 { w / sum } else { 1.0f32 }
  val rowBoxes: List[Box] = newList()
  var cy = y
  var ri = 0
  for r in rows {
    val rp = childPath(path, ri)
    val cellBoxes: List[Box] = newList()
    var cx = x
    var rowH = 0.0f32
    var k = 0
    for c in childrenOf(r) {
      val cwid = (if k < widths.count { widths[k] } else { 40.0f32 }) * scale
      val header = flag(propsOfWire(c), "header")
      val st = if header { styleBold } else { styleBody }
      val txt = textOfWire(c)
      val h = env.metrics.measure(txt, st, cwid - 20.0f32).h + 16.0f32
      rowH = maxF(rowH, h)
      cellBoxes.add(
        textBox("tableCell", childPath(rp, k), keyOfWireNode(c), propsOfWire(c), newList(), txt, st, cx, cy, cwid, h, false)
      )
      cx = cx + cwid
      k = k + 1
    }
    val fixed: List[Box] = newList()
    for cb in cellBoxes {
      fixed.add(cb.copy(h = rowH))
    }
    val hasClick = containsString(eventsOfWire(r), "click")
    rowBoxes.add(
      Box(
        kind = "tableRow",
        path = rp,
        key = keyOfWireNode(r),
        props = propsOfWire(r),
        events = eventsOfWire(r),
        text = "",
        style = styleBody,
        x = x,
        y = cy,
        w = w,
        h = rowH,
        children = fixed,
        focusable = hasClick,
        contentHeight = 0.0f32
      )
    )
    cy = cy + rowH
    ri = ri + 1
  }
  containerBox("table", path, key, props, events, x, y, w, cy - y, rowBoxes)
}

func containsString(xs: List[String], s: String): Bool {
  for x in xs {
    if x == s {
      return true
    }
  }
  false
}

func propsOfWire(n: WireNode): List[Prop] {
  match n {
    case WElement(_, _, props, _, _) -> props
    case _ -> newList()
  }
}

func eventsOfWire(n: WireNode): List[String] {
  match n {
    case WElement(_, _, _, events, _) -> events
    case _ -> newList()
  }
}

func keyOfWireNode(n: WireNode): String {
  match n {
    case WElement(_, key, _, _, _) -> key
    case _ -> ""
  }
}

// ─── Data grid ────────────────────────────────────────────────────────────────
/// One column of a data grid's `columns` property.
pub record GridCol {
  id: String
  title: String
  sort: String
}

/// The columns a data grid's `columns` property (a JSON array of `{id, title, sort?}`) names.
pub func gridColumns(props: in List[Prop]): List[GridCol] {
  val acc: List[GridCol] = newList()
  val raw = propOf(props, "columns", "[]")
  match parseValue(raw) {
    case Ok(JArray(items)) -> {
      for item in items {
        val id = match getString(item, "id") { case Some(s) -> s; case None -> "" }
        val title = match getString(item, "title") { case Some(s) -> s; case None -> "" }
        val sort = match getString(item, "sort") { case Some(s) -> s; case None -> "" }
        acc.add(GridCol(id = id, title = title, sort = sort))
      }
    }
    case _ -> ()
  }
  acc
}

func intProp(props: List[Prop], name: String, fallback: Int): Int {
  match parseOptInt(propOf(props, name, "")) {
    case Some(v) -> if v >= 0 { v } else { fallback }
    case None -> fallback
  }
}

func gridBox(
  n: WireNode,
  path: List[Int],
  key: String,
  props: List[Prop],
  events: List[String],
  x: Float,
  y: Float,
  w: Float,
  env: Env,
): Box {
  val cols = gridColumns(props)
  val colCount = if cols.count > 0 { cols.count } else { 1 }
  val rowH = intProp(props, "rowHeight", 36).toFloat()
  val rowHeight = if rowH > 0.0f32 { rowH } else { 36.0f32 }
  val total = intProp(props, "rowCount", 0)
  val firstRow = intProp(props, "firstRow", 0)
  val visible = intProp(props, "visibleRows", 10)
  val bodyH = visible.toFloat() * rowHeight
  val cw = (w - 2.0f32) / colCount.toFloat()
  val kids: List[Box] = newList()
  // Header: one cell per column, a button when the column sorts.
  var hx = x + 1.0f32
  var ci = 0
  for c in cols {
    kids.add(
      textBox(
        "colheader",
        childPath(path, -1 - ci),
        c.id,
        [Prop(name = "sort", value = c.sort), Prop(name = "id", value = c.id)],
        newList(),
        c.title,
        styleBold,
        hx,
        y + 1.0f32,
        cw,
        rowHeight,
        c.sort.length > 0
      )
    )
    hx = hx + cw
    ci = ci + 1
  }
  val scroll = env.gridScroll(path)
  val bodyTop = y + 1.0f32 + rowHeight
  val rowBoxes: List[Box] = newList()
  var ri = 0
  for r in childrenOf(n) {
    val rp = childPath(path, ri)
    val ry = bodyTop + (firstRow + ri).toFloat() * rowHeight - scroll
    val cells: List[Box] = newList()
    var k = 0
    for c in childrenOf(r) {
      val cx = x + 1.0f32 + k.toFloat() * cw
      val inner = layoutNode(c, childPath(rp, k), cx + 10.0f32, ry, cw - 20.0f32, env)
      val centred = moveBox(inner, 0.0f32, (rowHeight - inner.h) / 2.0f32)
      cells.add(
        containerBox("gridCell", childPath(rp, k), keyOfWireNode(c), newList(), newList(), cx, ry, cw, rowHeight, [centred])
      )
      k = k + 1
    }
    rowBoxes.add(
      Box(
        kind = "gridRow",
        path = rp,
        key = keyOfWireNode(r),
        props = propsOfWire(r),
        events = eventsOfWire(r),
        text = "",
        style = styleBody,
        x = x + 1.0f32,
        y = ry,
        w = w - 2.0f32,
        h = rowHeight,
        children = cells,
        focusable = false,
        contentHeight = 0.0f32
      )
    )
    ri = ri + 1
  }
  val body = Box(
    kind = "gridBody",
    path = path,
    key = "",
    props = newList(),
    events = newList(),
    text = "",
    style = styleBody,
    x = x + 1.0f32,
    y = bodyTop,
    w = w - 2.0f32,
    h = bodyH,
    children = rowBoxes,
    focusable = true,
    contentHeight = total.toFloat() * rowHeight
  )
  kids.add(body)
  containerBox("dataGrid", path, key, props, events, x, y, w, bodyH + rowHeight + 2.0f32, kids)
}

// ─── Dialog ───────────────────────────────────────────────────────────────────
func dialogBox(n: WireNode, path: List[Int], key: String, props: List[Prop], events: List[String], env: Env): Box {
  val t = env.theme
  val pw = minF(420.0f32, env.windowWidth - 32.0f32)
  val inner = stackBox(
    "dialogBody",
    n,
    path,
    "",
    newList(),
    newList(),
    0.0f32,
    0.0f32,
    pw - 40.0f32,
    16.0f32,
    0.0f32,
    env
  )
  val ph = inner.h + 40.0f32
  val px = (env.windowWidth - pw) / 2.0f32
  val py = maxF(16.0f32, (env.windowHeight - ph) / 2.0f32)
  val panel = containerBox(
    "dialogPanel",
    path,
    "",
    newList(),
    newList(),
    px,
    py,
    pw,
    ph,
    [moveBox(inner, px + 20.0f32, py + 20.0f32)]
  )
  containerBox("dialog", path, key, props, events, 0.0f32, 0.0f32, env.windowWidth, env.windowHeight, [panel])
}

// ─── Fixed-width metrics, for tests ───────────────────────────────────────────
/// Metrics where every character is `charWidth` wide and every line `lineHeight` tall (bold and
/// headings scale both by their style), with greedy word wrapping.
pub func fixedMetrics(charWidth: in Float, lineHeight: in Float): Metrics {
  Metrics(
    measure = { text: String, style: Int, maxWidth: Float ->
      val scale = styleScale(style)
      val cw = charWidth * scale
      val lh = lineHeight * scale
      if maxWidth <= 0.0f32 {
        Size(w = text.length.toFloat() * cw, h = lh)
      } else {
        val perLine = (maxWidth / cw).toInt()
        val limit = if perLine < 1 { 1 } else { perLine }
        var lines = 1
        var used = 0
        var widest = 0
        for word in split(text, " ") {
          val len = word.length
          if used == 0 {
            used = len
          } else if used + 1 + len <= limit {
            used = used + 1 + len
          } else {
            lines = lines + 1
            used = len
          }
          if used > widest {
            widest = used
          }
        }
        Size(w = (if widest > limit { limit } else { widest }).toFloat() * cw, h = lines.toFloat() * lh)
      }
    },
    lineHeight = { style: Int -> lineHeight * styleScale(style) }
  )
}

func styleScale(style: Int): Float {
  if style == styleH1 {
    1.8f32
  } else if style == styleH2 {
    1.4f32
  } else if style == styleH3 {
    1.2f32
  } else if style == styleSmall {
    0.9f32
  } else {
    1.0f32
  }
}

/// An `Env` for tests: the light theme, fixed metrics, no grid scroll.
pub func testEnv(windowWidth: in Float, windowHeight: in Float): Env {
  Env(
    theme = Ui.Native.Theme.light(),
    metrics = fixedMetrics(8.0f32, 20.0f32),
    windowWidth = windowWidth,
    windowHeight = windowHeight,
    gridScroll = { path: List[Int] -> 0.0f32 }
  )
}
