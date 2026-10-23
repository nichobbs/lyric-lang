//! paint.l - Ui.Native.Paint: draws laid-acc boxes with lyric-draw (docs/65 §13.3, docs/67 G10).
//!
//! `paintPage` walks the box tree `Ui.Native.Layout` produced and draws each widget in the style
//! of `runtime/ui.css`: surfaces with a border and radius, buttons in default, primary and
//! danger variants, inputs with a caret and selection, checkboxes, selects, tables, data grids with
//! a clipped scrolling body, banners and badges in their tones, a spinner, and a dialog over a
//! dimmed backdrop.  The state the picture depends on that is not in the tree (focus, hover, the
//! carets, the clock) is a `PaintCtx`.
//!
//! `Fonts` holds one fallback chain per text style; `metricsFor` makes the `Layout.Metrics`
//! that measures with the same chains, so a box is exactly as tall as the text drawn into it.
@io
package Ui.Native.Paint

import Std.Core
import Std.Collections
import Std.String
import Draw
import Text
import Ui.Core.{Prop}
import Ui.Native.Theme.{Theme, Rgba, withAlpha, toneColour, styleBody, styleBold, styleSmall, styleH1, styleH2, styleH3, styleCount}
import Ui.Native.Layout.{Box, Metrics, Size, propOf, textAreaPadding}
import Ui.Native.Interact.{TextEdit, cpSlice, cpCount}
import Ui.Native.Wrap

/// One font fallback chain per text style, indexed by the style numbers of `Ui.Native.Theme`.
pub record Fonts {
  chains: List[List[Text.Font]]
}

/// The metrics that measure with `fonts`.
pub func metricsFor(fonts: Fonts): Metrics {
  Metrics(
    measure = { text: String, style: Int, maxWidth: Float ->
      val chain = fonts.chains[style]
      val l = Text.layoutText(chain, text, maxWidth)
      val lh = chain[0].lineHeight
      Size(w = l.width, h = if l.height > lh { l.height } else { lh })
    },
    lineHeight = { style: Int -> fonts.chains[style][0].lineHeight }
  )
}

/// What a frame's picture depends on besides the boxes.
pub record PaintCtx {
  theme: Theme
  fonts: Fonts
  /// The id of the focused box ("" for none) and the hovered one, as `idOf` names them.
  focusId: String
  hoverId: String
  idOf: (Box) -> String
  /// The caret state of the input with an id.
  editOf: (String) -> TextEdit
  /// Seconds since the program started, for the caret blink and the spinner.
  time: Float
  /// Text being composed by an input method, drawn at the caret of the focused input.
  composing: String
  /// The id of the select whose popup is open ("" for none).
  openSelect: String
  /// Device pixels per logical pixel: the fonts are opened at this multiple of their logical size.
  scale: Float
  /// The wrapped lines of a text area showing a text (cached by the host, since shaping is not free).
  areaLines: (Box, String) -> List[Wrap.VisualLine]
}

func col(c: Rgba): Draw.Color {
  Draw.rgba(c.r, c.g, c.b, c.a)
}

func rect(x: Float, y: Float, w: Float, h: Float): Draw.Rect {
  Draw.Rect(x = x, y = y, width = w, height = h)
}

func say(ctx: PaintCtx, p: Draw.Painter, style: Int, text: String, x: Float, y: Float, maxWidth: Float, c: Rgba): Unit {
  if text.length > 0 {
    match Draw.drawText(p, ctx.fonts.chains[style], text, x, y, maxWidth, col(c)) {
      case Ok(_) -> ()
      case Err(_) -> ()
    }
  }
}

// A run of one direction, as the Unicode Bidirectional Algorithm gives it.
func sayRun(ctx: PaintCtx, p: Draw.Painter, style: Int, text: String, rtl: Bool, x: Float, y: Float, c: Rgba): Unit {
  if text.length > 0 {
    match Draw.drawTextRun(p, ctx.fonts.chains[style], text, rtl, x, y, col(c)) {
      case Ok(_) -> ()
      case Err(_) -> ()
    }
  }
}

// The fonts are opened at the display's scale, so their sizes are in device pixels; positions are
// in logical pixels.
func lineOf(ctx: PaintCtx, style: Int): Float {
  ctx.fonts.chains[style][0].lineHeight / ctx.scale
}

// The advance of `text`, trailing spaces included: a layout leaves them out of a line's width, but a
// caret after a space is a space-width to the right of one before it.
func widthOf(ctx: PaintCtx, style: Int, text: String): Float {
  val chain = ctx.fonts.chains[style]
  if text.length > 0 and text.endsWith(" ") {
    (Text.measureText(chain, text + "x") - Text.measureText(chain, "x")) / ctx.scale
  } else {
    Text.measureText(chain, text) / ctx.scale
  }
}

func flag(props: List[Prop], name: String): Bool {
  propOf(props, name, "") == "true"
}

/// Draws the whole page.
pub func paintPage(page: in Box, p: in Draw.Painter, ctx: in PaintCtx): Unit {
  for c in page.children {
    paintBox(c, p, ctx, false)
  }
}

func focusRing(p: Draw.Painter, ctx: PaintCtx, b: Box, radius: Float): Unit {
  Draw.strokeRoundedRect(
    p,
    rect(b.x - 2.0f32, b.y - 2.0f32, b.w + 4.0f32, b.h + 4.0f32),
    radius + 2.0f32,
    2.0f32,
    col(ctx.theme.accent)
  )
}

func paintBox(b: Box, p: Draw.Painter, ctx: PaintCtx, invalid: Bool): Unit {
  val t = ctx.theme
  val id = ctx.idOf(b)
  val focused = id.length > 0 and id == ctx.focusId
  val hovered = id.length > 0 and id == ctx.hoverId
  val kind = b.kind
  if kind == "text" or kind == "paragraph" {
    say(ctx, p, b.style, b.text, b.x, b.y, b.w, t.text)
  } else if kind == "label" {
    say(ctx, p, b.style, b.text, b.x, b.y, 0.0f32, t.text)
  } else if kind == "heading" or kind == "cardTitle" or kind == "fieldLabel" {
    say(ctx, p, b.style, b.text, b.x, b.y, b.w, t.text)
  } else if kind == "fieldError" {
    say(ctx, p, b.style, b.text, b.x, b.y, b.w, t.danger)
  } else if kind == "badge" {
    val c = toneColour(t, propOf(b.props, "tone", "info"))
    Draw.strokeRoundedRect(p, rect(b.x, b.y, b.w, b.h), b.h / 2.0f32, 1.0f32, col(c))
    say(ctx, p, b.style, b.text, b.x + 9.0f32, b.y + 2.0f32, 0.0f32, c)
  } else if kind == "banner" {
    val c = toneColour(t, propOf(b.props, "tone", "info"))
    Draw.fillRoundedRect(p, rect(b.x, b.y, b.w, b.h), t.radius, col(t.surface))
    Draw.fillRect(p, rect(b.x, b.y, 4.0f32, b.h), col(c))
    say(ctx, p, styleBody, b.text, b.x + 16.0f32, b.y + 10.0f32, b.w - 28.0f32, t.text)
  } else if kind == "spinner" {
    paintSpinner(b, p, ctx)
  } else if kind == "card" or kind == "section" {
    Draw.fillRoundedRect(p, rect(b.x, b.y, b.w, b.h), t.radius, col(t.surface))
    Draw.strokeRoundedRect(p, rect(b.x, b.y, b.w, b.h), t.radius, 1.0f32, col(t.border))
    paintChildren(b, p, ctx, invalid)
  } else if kind == "field" {
    paintChildren(b, p, ctx, flag(b.props, "invalid"))
  } else if kind == "button" {
    paintButton(b, p, ctx, focused, hovered)
  } else if kind == "link" {
    say(ctx, p, b.style, b.text, b.x, b.y, 0.0f32, t.accent)
    if hovered or focused {
      Draw.fillRect(p, rect(b.x, b.y + lineOf(ctx, b.style) - 1.0f32, b.w, 1.0f32), col(t.accent))
    }
    if focused {
      focusRing(p, ctx, b, 3.0f32)
    }
  } else if kind == "textInput" or kind == "numberInput" or kind == "dateInput" or kind == "textArea" {
    paintInput(b, p, ctx, id, focused, invalid)
  } else if kind == "checkbox" {
    paintCheckbox(b, p, ctx, focused)
  } else if kind == "select" {
    paintSelect(b, p, ctx, focused, invalid)
  } else if kind == "table" {
    Draw.fillRect(p, rect(b.x, b.y, b.w, b.h), col(t.surface))
    paintChildren(b, p, ctx, invalid)
  } else if kind == "tableRow" {
    if hovered or focused {
      Draw.fillRect(p, rect(b.x, b.y, b.w, b.h), col(withAlpha(t.accent, 0.08f32)))
    }
    paintChildren(b, p, ctx, invalid)
    if focused {
      Draw.strokeRoundedRect(p, rect(b.x, b.y, b.w, b.h), 0.0f32, 2.0f32, col(t.accent))
    }
  } else if kind == "tableCell" {
    say(ctx, p, b.style, b.text, b.x + 10.0f32, b.y + 8.0f32, b.w - 20.0f32, t.text)
    Draw.fillRect(p, rect(b.x, b.y + b.h - 1.0f32, b.w, 1.0f32), col(t.border))
  } else if kind == "dataGrid" {
    paintGrid(b, p, ctx, invalid)
  } else if kind == "dialog" {
    Draw.fillRect(p, rect(b.x, b.y, b.w, b.h), col(Rgba(r = 0.0f32, g = 0.0f32, b = 0.0f32, a = 0.4f32)))
    for c in b.children {
      val panel = c
      Draw.drawShadow(
        p,
        rect(panel.x, panel.y, panel.w, panel.h),
        t.radius,
        12.0f32,
        col(Rgba(r = 0.0f32, g = 0.0f32, b = 0.0f32, a = 0.3f32))
      )
      Draw.fillRoundedRect(p, rect(panel.x, panel.y, panel.w, panel.h), t.radius, col(t.surface))
      paintChildren(panel, p, ctx, false)
    }
  } else if kind == "empty" or kind == "spacer" or kind == "option" or kind == "toast" {
    ()
  } else {
    paintChildren(b, p, ctx, invalid)
  }
}

func paintChildren(b: Box, p: Draw.Painter, ctx: PaintCtx, invalid: Bool): Unit {
  for c in b.children {
    paintBox(c, p, ctx, invalid)
  }
}

func paintSpinner(b: Box, p: Draw.Painter, ctx: PaintCtx): Unit {
  val t = ctx.theme
  val cx = b.x + 12.0f32
  val cy = b.y + 12.0f32
  val phase = (ctx.time * 10.0f32).toInt() % 8
  var i = 0
  while i < 8 {
    val a = i.toFloat() * 0.78539816f32
    val dx = unitCos(a) * 9.0f32
    val dy = unitSin(a) * 9.0f32
    val age = (i + 8 - phase) % 8
    val alpha = 0.15f32 + 0.85f32 * (1.0f32 - age.toFloat() / 8.0f32)
    Draw.fillRoundedRect(
      p,
      rect(cx + dx - 2.0f32, cy + dy - 2.0f32, 4.0f32, 4.0f32),
      2.0f32,
      col(withAlpha(t.accent, alpha))
    )
    i = i + 1
  }
}

// Eight fixed directions, so the spinner needs no trigonometry library.
func unitCos(a: Float): Float {
  val k = ((a / 0.78539816f32) + 0.5f32).toInt() % 8
  if k == 0 {
    1.0f32
  } else if k == 1 {
    0.70710678f32
  } else if k == 2 {
    0.0f32
  } else if k == 3 {
    -0.70710678f32
  } else if k == 4 {
    -1.0f32
  } else if k == 5 {
    -0.70710678f32
  } else if k == 6 {
    0.0f32
  } else {
    0.70710678f32
  }
}

func unitSin(a: Float): Float {
  val k = ((a / 0.78539816f32) + 0.5f32).toInt() % 8
  if k == 0 {
    0.0f32
  } else if k == 1 {
    0.70710678f32
  } else if k == 2 {
    1.0f32
  } else if k == 3 {
    0.70710678f32
  } else if k == 4 {
    0.0f32
  } else if k == 5 {
    -0.70710678f32
  } else if k == 6 {
    -1.0f32
  } else {
    -0.70710678f32
  }
}

func paintButton(b: Box, p: Draw.Painter, ctx: PaintCtx, focused: Bool, hovered: Bool): Unit {
  val t = ctx.theme
  val variant = propOf(b.props, "variant", "default")
  val blocked = flag(b.props, "disabled") or flag(b.props, "busy")
  var fill = t.surface
  var edge = t.border
  var ink = t.text
  if variant == "primary" {
    fill = t.accent
    edge = t.accent
    ink = t.accentText
  } else if variant == "danger" {
    fill = t.danger
    edge = t.danger
    ink = t.accentText
  }
  val dim = if blocked { 0.6f32 } else { 1.0f32 }
  val shade = if hovered and not blocked { 0.92f32 } else { 1.0f32 }
  Draw.fillRoundedRect(
    p,
    rect(b.x, b.y, b.w, b.h),
    t.radius,
    col(withAlpha(Rgba(r = fill.r * shade, g = fill.g * shade, b = fill.b * shade, a = 1.0f32), dim))
  )
  Draw.strokeRoundedRect(p, rect(b.x, b.y, b.w, b.h), t.radius, 1.0f32, col(withAlpha(edge, dim)))
  val tw = widthOf(ctx, styleBold, b.text)
  say(
    ctx,
    p,
    styleBold,
    b.text,
    b.x + (b.w - tw) / 2.0f32,
    b.y + (b.h - lineOf(ctx, styleBold)) / 2.0f32,
    0.0f32,
    withAlpha(ink, dim)
  )
  if flag(b.props, "busy") {
    Draw.fillRect(
      p,
      rect(b.x + 6.0f32, b.y + b.h - 4.0f32, (b.w - 12.0f32) * 0.4f32, 2.0f32),
      col(withAlpha(ink, 0.7f32))
    )
  }
  if focused {
    focusRing(p, ctx, b, t.radius)
  }
}

func paintInput(b: Box, p: Draw.Painter, ctx: PaintCtx, id: String, focused: Bool, invalid: Bool): Unit {
  if b.kind == "textArea" {
    paintTextArea(b, p, ctx, id, focused, invalid)
    return
  }
  val t = ctx.theme
  val pad = t.inputPadding
  val edge = if invalid { t.danger } else { t.border }
  Draw.fillRoundedRect(p, rect(b.x, b.y, b.w, b.h), t.radius, col(t.surface))
  Draw.strokeRoundedRect(p, rect(b.x, b.y, b.w, b.h), t.radius, 1.0f32, col(edge))
  val lh = lineOf(ctx, styleBody)
  val ty = b.y + (b.h - lh) / 2.0f32
  Draw.pushClip(p, rect(b.x + 1.0f32, b.y + 1.0f32, b.w - 2.0f32, b.h - 2.0f32))
  val e = if focused { ctx.editOf(id) } else { Ui.Native.Interact.emptyEdit() }
  val value = b.text
  val placeholder = propOf(b.props, "placeholder", "")
  val x0 = b.x + pad - (if focused { e.scrollX } else { 0.0f32 })
  if value.length == 0 and not (focused and ctx.composing.length > 0) {
    say(ctx, p, styleBody, placeholder, x0, ty, 0.0f32, t.muted)
  }
  if focused and e.anchor != e.caret {
    val a = if e.anchor < e.caret { e.anchor } else { e.caret }
    val z = if e.anchor < e.caret { e.caret } else { e.anchor }
    val sx = x0 + widthOf(ctx, styleBody, cpSlice(value, 0, a))
    val ex = x0 + widthOf(ctx, styleBody, cpSlice(value, 0, z))
    Draw.fillRect(p, rect(sx, ty, ex - sx, lh), col(withAlpha(t.accent, 0.3f32)))
  }
  if focused and ctx.composing.length > 0 {
    val cx = x0 + widthOf(ctx, styleBody, cpSlice(value, 0, e.caret))
    val before = cpSlice(value, 0, e.caret)
    val after = cpSlice(value, e.caret, cpCount(value))
    say(ctx, p, styleBody, before, x0, ty, 0.0f32, t.text)
    val cw = widthOf(ctx, styleBody, ctx.composing)
    say(ctx, p, styleBody, ctx.composing, cx, ty, 0.0f32, t.text)
    Draw.fillRect(p, rect(cx, ty + lh - 1.0f32, cw, 1.0f32), col(t.text))
    say(ctx, p, styleBody, after, cx + cw, ty, 0.0f32, t.text)
  } else {
    say(ctx, p, styleBody, value, x0, ty, 0.0f32, t.text)
  }
  if focused and (ctx.time * 2.0f32).toInt() % 2 == 0 {
    val cx = x0 + widthOf(ctx, styleBody, cpSlice(value, 0, e.caret)) +
      (if ctx.composing.length > 0 { widthOf(ctx, styleBody, ctx.composing) } else { 0.0f32 })
    Draw.fillRect(p, rect(cx, ty, 1.0f32, lh), col(t.text))
  }
  Draw.popClip(p)
  if focused {
    focusRing(p, ctx, b, t.radius)
  }
}

// A text area: the wrapped lines of its text from the top, shifted up by its scroll, with the
// selection as one band per line, the text being composed underlined, and the caret on its line.
func paintTextArea(b: Box, p: Draw.Painter, ctx: PaintCtx, id: String, focused: Bool, invalid: Bool): Unit {
  val t = ctx.theme
  val edge = if invalid { t.danger } else { t.border }
  Draw.fillRoundedRect(p, rect(b.x, b.y, b.w, b.h), t.radius, col(t.surface))
  Draw.strokeRoundedRect(p, rect(b.x, b.y, b.w, b.h), t.radius, 1.0f32, col(edge))
  val lh = lineOf(ctx, styleBody)
  val e = ctx.editOf(id)
  val value = b.text
  val composing = if focused { ctx.composing } else { "" }
  val n = cpCount(value)
  val caret = if e.caret > n { n } else if e.caret < 0 { 0 } else { e.caret }
  val shown = if composing.length > 0 { cpSlice(value, 0, caret) + composing + cpSlice(value, caret, n) } else { value }
  val lines = ctx.areaLines(b, shown)
  val left = b.x + t.inputPadding
  val top = b.y + textAreaPadding - e.scrollY
  val widthOfText = { s: String -> widthOf(ctx, styleBody, s) }
  Draw.pushClip(p, rect(b.x + 1.0f32, b.y + 1.0f32, b.w - 2.0f32, b.h - 2.0f32))
  if value.length == 0 and composing.length == 0 {
    say(ctx, p, styleBody, propOf(b.props, "placeholder", ""), left, top, 0.0f32, t.muted)
  }
  if focused and e.anchor != e.caret and composing.length == 0 {
    val a = if e.anchor < e.caret { e.anchor } else { e.caret }
    val z = if e.anchor < e.caret { e.caret } else { e.anchor }
    for band in Wrap.selectionBands(shown, lines, a, z, widthOfText) {
      Draw.fillRect(
        p,
        rect(left + band.x0, top + band.row.toFloat() * lh, band.x1 - band.x0, lh),
        col(withAlpha(t.accent, 0.3f32))
      )
    }
  }
  var row = 0
  for l in lines {
    val y = top + row.toFloat() * lh
    if y + lh >= b.y and y <= b.y + b.h {
      for piece in Wrap.linePieces(shown, lines, row, widthOfText) {
        sayRun(ctx, p, styleBody, piece.text, piece.level % 2 == 1, left + piece.textX, y, t.text)
      }
    }
    row = row + 1
  }
  if composing.length > 0 {
    for band in Wrap.selectionBands(shown, lines, caret, caret + cpCount(composing), widthOfText) {
      Draw.fillRect(
        p,
        rect(left + band.x0, top + band.row.toFloat() * lh + lh - 1.0f32, band.x1 - band.x0, 1.0f32),
        col(t.text)
      )
    }
  }
  if focused and (ctx.time * 2.0f32).toInt() % 2 == 0 {
    val at = caret + cpCount(composing)
    val caretRow = Wrap.lineIndexOf(lines, at)
    val cx = left + Wrap.offsetInRow(shown, lines, caretRow, at, widthOfText)
    Draw.fillRect(p, rect(cx, top + caretRow.toFloat() * lh, 1.0f32, lh), col(t.text))
  }
  Draw.popClip(p)
  if focused {
    focusRing(p, ctx, b, t.radius)
  }
}

func paintCheckbox(b: Box, p: Draw.Painter, ctx: PaintCtx, focused: Bool): Unit {
  val t = ctx.theme
  val checked = flag(b.props, "checked")
  val dim = if flag(b.props, "disabled") { 0.6f32 } else { 1.0f32 }
  val boxRect = rect(b.x, b.y + (b.h - 18.0f32) / 2.0f32, 18.0f32, 18.0f32)
  if checked {
    Draw.fillRoundedRect(p, boxRect, 4.0f32, col(withAlpha(t.accent, dim)))
    say(ctx, p, styleBody, "✓", boxRect.x + 2.0f32, boxRect.y - 1.0f32, 0.0f32, t.accentText)
  } else {
    Draw.fillRoundedRect(p, boxRect, 4.0f32, col(t.surface))
    Draw.strokeRoundedRect(p, boxRect, 4.0f32, 1.0f32, col(withAlpha(t.border, dim)))
  }
  say(
    ctx,
    p,
    styleBody,
    b.text,
    b.x + 26.0f32,
    b.y + (b.h - lineOf(ctx, styleBody)) / 2.0f32,
    0.0f32,
    withAlpha(t.text, dim)
  )
  if focused {
    focusRing(
      p,
      ctx,
      Box(
        kind = "x",
        path = b.path,
        key = "",
        props = b.props,
        events = b.events,
        text = "",
        style = 0,
        x = boxRect.x,
        y = boxRect.y,
        w = 18.0f32,
        h = 18.0f32,
        children = newList(),
        focusable = true,
        contentHeight = 0.0f32
      ),
      4.0f32
    )
  }
}

func paintSelect(b: Box, p: Draw.Painter, ctx: PaintCtx, focused: Bool, invalid: Bool): Unit {
  val t = ctx.theme
  val edge = if invalid { t.danger } else { t.border }
  Draw.fillRoundedRect(p, rect(b.x, b.y, b.w, b.h), t.radius, col(t.surface))
  Draw.strokeRoundedRect(p, rect(b.x, b.y, b.w, b.h), t.radius, 1.0f32, col(edge))
  Draw.pushClip(p, rect(b.x + 1.0f32, b.y + 1.0f32, b.w - 26.0f32, b.h - 2.0f32))
  say(ctx, p, styleBody, b.text, b.x + t.inputPadding, b.y + (b.h - lineOf(ctx, styleBody)) / 2.0f32, 0.0f32, t.text)
  Draw.popClip(p)
  say(ctx, p, styleBody, "▾", b.x + b.w - 22.0f32, b.y + (b.h - lineOf(ctx, styleBody)) / 2.0f32, 0.0f32, t.muted)
  if focused {
    focusRing(p, ctx, b, t.radius)
  }
}

func paintGrid(b: Box, p: Draw.Painter, ctx: PaintCtx, invalid: Bool): Unit {
  val t = ctx.theme
  Draw.fillRoundedRect(p, rect(b.x, b.y, b.w, b.h), t.radius, col(t.surface))
  for c in b.children {
    if c.kind == "colheader" {
      val sort = propOf(c.props, "sort", "")
      var title = c.text
      if sort == "ascending" {
        title = title + " ▲"
      } else if sort == "descending" {
        title = title + " ▼"
      }
      val hovered = c.focusable and ctx.hoverId == ctx.idOf(c)
      say(
        ctx,
        p,
        styleBold,
        title,
        c.x + 10.0f32,
        c.y + (c.h - lineOf(ctx, styleBold)) / 2.0f32,
        c.w - 20.0f32,
        if hovered { t.accent } else { t.text }
      )
      if ctx.focusId.length > 0 and ctx.focusId == ctx.idOf(c) {
        focusRing(p, ctx, c, 2.0f32)
      }
    } else if c.kind == "gridBody" {
      Draw.fillRect(p, rect(c.x, c.y - 1.0f32, c.w, 1.0f32), col(t.border))
      Draw.pushClip(p, rect(c.x, c.y, c.w, c.h))
      for row in c.children {
        val id = ctx.idOf(row)
        val hovered = id.length > 0 and id == ctx.hoverId
        val focused = id.length > 0 and id == ctx.focusId
        if hovered or focused {
          Draw.fillRect(p, rect(row.x, row.y, row.w, row.h), col(withAlpha(t.accent, 0.08f32)))
        }
        Draw.fillRect(p, rect(row.x, row.y + row.h - 1.0f32, row.w, 1.0f32), col(t.border))
        for cell in row.children {
          paintChildren(cell, p, ctx, invalid)
        }
        if focused {
          Draw.strokeRoundedRect(p, rect(row.x, row.y, row.w, row.h), 0.0f32, 2.0f32, col(t.accent))
        }
      }
      // A scroll bar when the rows do not all fit.
      if c.contentHeight > c.h {
        val ratio = c.h / c.contentHeight
        val barH = if c.h * ratio < 24.0f32 { 24.0f32 } else { c.h * ratio }
        val first = c.children.count
        Draw.fillRoundedRect(
          p,
          rect(c.x + c.w - 6.0f32, c.y + 2.0f32, 4.0f32, barH),
          2.0f32,
          col(withAlpha(t.muted, 0.35f32))
        )
      }
      Draw.popClip(p)
    }
  }
  Draw.strokeRoundedRect(p, rect(b.x, b.y, b.w, b.h), t.radius, 1.0f32, col(t.border))
}

/// The popup of an open select: its options in a list under the box, the hovered one tinted.
pub func paintSelectPopup(
  box: in Box, choices: in List[String], hover: in Int, p: in Draw.Painter, ctx: in PaintCtx
): Unit {
  val t = ctx.theme
  val rowH = t.controlHeight
  val h = rowH * choices.count.toFloat()
  Draw.drawShadow(
    p,
    rect(box.x, box.y + box.h + 2.0f32, box.w, h),
    t.radius,
    8.0f32,
    col(Rgba(r = 0.0f32, g = 0.0f32, b = 0.0f32, a = 0.25f32))
  )
  Draw.fillRoundedRect(p, rect(box.x, box.y + box.h + 2.0f32, box.w, h), t.radius, col(t.surface))
  Draw.strokeRoundedRect(p, rect(box.x, box.y + box.h + 2.0f32, box.w, h), t.radius, 1.0f32, col(t.border))
  var i = 0
  for c in choices {
    val y = box.y + box.h + 2.0f32 + i.toFloat() * rowH
    if i == hover {
      Draw.fillRect(p, rect(box.x + 1.0f32, y, box.w - 2.0f32, rowH), col(withAlpha(t.accent, 0.15f32)))
    }
    say(
      ctx,
      p,
      styleBody,
      c,
      box.x + t.inputPadding,
      y + (rowH - lineOf(ctx, styleBody)) / 2.0f32,
      box.w - 18.0f32,
      t.text
    )
    i = i + 1
  }
}

/// The toasts, stacked up from the bottom-right corner of a `width` by `height` window.
pub func paintToasts(
  messages: in List[String],
  tones: in List[String],
  width: in Float,
  height: in Float,
  p: in Draw.Painter,
  ctx: in PaintCtx,
): Unit {
  val t = ctx.theme
  var y = height - 16.0f32
  var i = messages.count - 1
  while i >= 0 {
    val m = messages[i]
    val tw = widthOf(ctx, styleBody, m) + 32.0f32
    val h = lineOf(ctx, styleBody) + 20.0f32
    val x = width - 16.0f32 - tw
    y = y - h
    Draw.drawShadow(p, rect(x, y, tw, h), t.radius, 8.0f32, col(Rgba(r = 0.0f32, g = 0.0f32, b = 0.0f32, a = 0.25f32)))
    Draw.fillRoundedRect(p, rect(x, y, tw, h), t.radius, col(t.surface))
    Draw.strokeRoundedRect(p, rect(x, y, tw, h), t.radius, 1.0f32, col(t.border))
    Draw.fillRect(p, rect(x, y, 4.0f32, h), col(toneColour(t, tones[i])))
    say(ctx, p, styleBody, m, x + 16.0f32, y + 10.0f32, 0.0f32, t.text)
    y = y - 8.0f32
    i = i - 1
  }
}
