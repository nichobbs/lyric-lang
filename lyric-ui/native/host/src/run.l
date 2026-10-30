//! run.l - Ui.Native.Run: the native window host for lyric-ui (docs/65 §13.3, docs/67 G10).
//!
//!   func route(url: in String): Option[Instance] { ... }   // app-defined, the same as for the web host
//!   func main(): Int { Native.run(Native.defaultConfig("Customers"), route) }
//!
//! The host is the session protocol's client, in-process: it starts an `Ui.Host.Instance` with an
//! outbox that queues the JSON the instance sends (effects deliver on their own threads, so the
//! queue is a protected type), applies each patch message to its mirror of the tree
//! (`Ui.Native.Client`), lays the tree out (`Ui.Native.Layout`), paints it with lyric-draw
//! (`Ui.Native.Paint`), and turns what the user does into protocol events for
//! `Instance.receive`: clicks on buttons, rows and checkboxes, typing, form submission, grid scrolling
//! and sorting, link navigation, select choices.  Application code is the same as for the web and
//! desktop hosts; only the entry point differs.
//!
//! Input: mouse, keyboard with Tab focus traversal, a caret and selection in text inputs, clipboard
//! (Ctrl or Cmd with A, C, X and V), input-method composition (the candidate window follows the
//! caret), mouse wheel scrolling of the page and of data grids, Enter to submit a form and to
//! activate the focused control, Up and Down between grid rows and select options.
//!
//! `Host` is the state of one window or one headless session; `openHost`, `pump`, `handle` and
//! `renderFrame` are what both `run` and `renderHeadless` drive, so a scripted headless session
//! exercises the same code a user does.
@io
package Ui.Native.Run

import Std.Core
import Std.Collections
import Std.String
import Std.Parse.{parseOptInt}
import Std.Console as Console
import Std.Environment as Environment
import Std.File as File
import Std.Time as Time
import Window
import Gpu
import Draw
import Text
import Ui.Host.{Instance, Outbox}
import Ui.Diff.{WireNode, WElement, WText, WEmpty, SetProp}
import Ui.Protocol.{Event, EventMsg, NodeRef, refsKey, pathKey}
import Ui.Native.Theme.{Theme, light, dark, styleCount}
import Ui.Native.Client.{ServerMessage, PatchMsg, NavigateMsg, BackMsg, ToastMsg, SessionIdMsg, decodeServer, applyServer, eventPath, nodeAt}
import Ui.Native.Layout.{Box, Env, Metrics, layoutTree, propOf, textOfWire, textAreaPadding}
import Ui.Native.Interact
import Ui.Native.Wrap
import Ui.Native.Interact.{TextEdit, Action}
import Ui.Native.Paint.{Fonts, PaintCtx, metricsFor, paintPage, paintSelectPopup, paintToasts}

// ─── Configuration ────────────────────────────────────────────────────────────
/// The window and its fonts.  `fontPath` and `boldFontPath` are TrueType files; `cjkFontPath`, when
/// not empty, is a fallback for characters the main font lacks.  The environment variables
/// LYRIC_UI_FONT, LYRIC_UI_FONT_BOLD and LYRIC_UI_FONT_CJK override them.
pub record NativeConfig {
  title: String
  width: Int
  height: Int
  startPath: String
  dark: Bool
  fontPath: String
  boldFontPath: String
  cjkFontPath: String
}

pub func defaultConfig(title: in String): NativeConfig {
  NativeConfig(
    title = title,
    width = 1024,
    height = 768,
    startPath = "/",
    dark = false,
    fontPath = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    boldFontPath = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    cjkFontPath = ""
  )
}

// ─── The message queue ────────────────────────────────────────────────────────
/// The JSON an instance sent, waiting for the host's thread.  Effects run on their own threads
/// and send through the outbox, so every member is an `entry`.
pub protected type Inbox {
  var messages: List[String] = newList()
  entry push(text: in String) {
    messages.add(text)
  }
  entry take(): List[String] {
    val taken = messages
    messages = newList()
    return taken
  }
}

record InboxOutbox {
  inbox: Inbox
}

impl Outbox for InboxOutbox {
  func send(text: in String): Unit {
    self.inbox.push(text)
  }
}

// ─── Host state ───────────────────────────────────────────────────────────────
pub record Toasting {
  message: String
  tone: String
  until: Float
}

/// The state of one window (or headless session).
pub ref record Host {
  cfg: NativeConfig
  route: (String) -> Option[Instance]
  theme: Theme
  fonts: Fonts
  metrics: Metrics
  scale: Float
  var width: Float
  var height: Float
  var instance: Option[Instance]
  var inbox: Inbox
  var url: String
  var history: List[String]
  var tree: WireNode
  var renderVersion: Int
  var focus: String
  var hover: String
  var edits: Map[String, TextEdit]
  var versions: Map[String, Int]
  var gridScroll: Map[String, Float]
  var reported: Map[String, String]
  var pageScroll: Float
  var openSelect: String
  var selectHover: Int
  var composing: String
  var toasts: List[Toasting]
  var dragging: String
  var mouseX: Float
  var mouseY: Float
  var page: Box
  var now: Float
  var quit: Bool
  /// The wrapped lines of each text area (by id) for the text and width they were made for.
  var wraps: Map[String, WrapEntry]
}

pub record WrapEntry {
  value: String
  width: Float
  lines: List[Wrap.VisualLine]
}

func emptyPage(): Box {
  Box(
    kind = "page",
    path = newList(),
    key = "",
    props = newList(),
    events = newList(),
    text = "",
    style = 0,
    x = 0.0f32,
    y = 0.0f32,
    w = 0.0f32,
    h = 0.0f32,
    children = newList(),
    focusable = false,
    contentHeight = 0.0f32
  )
}

/// A host of `width` by `height` logical pixels on a display of `scale`, drawing with `fonts` (opened
/// at the scaled size).  Call `navigate` to open the first screen.
pub func openHost(
  cfg: in NativeConfig,
  route: in (String) -> Option[Instance],
  fonts: in Fonts,
  scale: in Float,
  width: in Float,
  height: in Float,
): Host {
  Host(
    cfg = cfg,
    route = route,
    theme = if cfg.dark { dark() } else { light() },
    fonts = fonts,
    metrics = scaledMetrics(fonts, scale),
    scale = scale,
    width = width,
    height = height,
    instance = None,
    inbox = Inbox(),
    url = "",
    history = newList(),
    tree = WEmpty,
    renderVersion = 0,
    focus = "",
    hover = "",
    edits = newMap(),
    versions = newMap(),
    gridScroll = newMap(),
    reported = newMap(),
    pageScroll = 0.0f32,
    openSelect = "",
    selectHover = 0,
    composing = "",
    toasts = newList(),
    dragging = "",
    mouseX = -1.0f32,
    mouseY = -1.0f32,
    page = emptyPage(),
    now = 0.0f32,
    quit = false,
    wraps = newMap()
  )
}

// Metrics in logical pixels from fonts opened at `scale` times their logical size.
func scaledMetrics(fonts: Fonts, scale: Float): Metrics {
  val m = metricsFor(fonts)
  Metrics(
    measure = { text: String, style: Int, maxWidth: Float ->
      val s = m.measure(text, style, maxWidth * scale)
      Ui.Native.Layout.Size(w = s.w / scale, h = s.h / scale)
    },
    lineHeight = { style: Int -> m.lineHeight(style) / scale }
  )
}

// ─── Fonts ────────────────────────────────────────────────────────────────────
func readFont(lib: Text.TextLib, id: Int, path: String, size: Int): Option[Text.Font] {
  if path.length == 0 {
    return None
  }
  match File.readBytes(path) {
    case Err(_) -> None
    case Ok(bytes) -> match Text.openFont(lib, id, bytes, 0, size) {
      case Ok(f) -> Some(value = f)
      case Err(_) -> None
    }
  }
}

func chainFor(lib: Text.TextLib, id: Int, primary: String, cjk: String, size: Int): Result[List[Text.Font], String] {
  val chain: List[Text.Font] = newList()
  match readFont(lib, id, primary, size) {
    case Some(f) -> chain.add(f)
    case None -> return Err(error = "cannot read the font " + primary + " (set LYRIC_UI_FONT)")
  }
  match readFont(lib, id + 100, cjk, size) {
    case Some(f) -> chain.add(f)
    case None -> ()
  }
  Ok(value = chain)
}

/// Opens the six text styles at `scale` times their logical size.
pub func openFonts(lib: Text.TextLib, cfg: NativeConfig, scale: Float): Result[Fonts, String] {
  val regular = Environment.getVarOrDefault("LYRIC_UI_FONT", cfg.fontPath)
  var bold = Environment.getVarOrDefault("LYRIC_UI_FONT_BOLD", cfg.boldFontPath)
  if not File.fileExists(bold) {
    bold = regular
  }
  val cjk = Environment.getVarOrDefault("LYRIC_UI_FONT_CJK", cfg.cjkFontPath)
  val sizes: List[Int] = newList()
  val faces: List[String] = newList()
  sizes.add(15)
  faces.add(regular)
  sizes.add(15)
  faces.add(bold)
  sizes.add(13)
  faces.add(regular)
  sizes.add(28)
  faces.add(bold)
  sizes.add(22)
  faces.add(bold)
  sizes.add(18)
  faces.add(bold)
  val chains: List[List[Text.Font]] = newList()
  var i = 0
  while i < sizes.count {
    val px = (sizes[i].toFloat() * scale + 0.5f32).toInt()
    match chainFor(lib, i + 1, faces[i], cjk, px) {
      case Ok(c) -> chains.add(c)
      case Err(e) -> return Err(error = e)
    }
    i = i + 1
  }
  Ok(value = Fonts(chains = chains))
}

pub func closeFonts(fonts: Fonts): Unit {
  for chain in fonts.chains {
    for f in chain {
      Text.closeFont(f)
    }
  }
}

// ─── Identity of boxes ────────────────────────────────────────────────────────
func parentPath(path: List[Int]): List[Int] {
  val p: List[Int] = newList()
  var i = 0
  while i < path.count - 1 {
    p.add(path[i])
    i = i + 1
  }
  p
}

/// A box's id: the keyed event path of its node, with a suffix for the parts of a data grid.
func idOfBox(h: Host, b: Box): String {
  if b.kind == "colheader" {
    return refsKey(eventPath(h.tree, parentPath(b.path))) + "#col:" + b.key
  }
  if b.kind == "gridBody" {
    return refsKey(eventPath(h.tree, b.path)) + "#body"
  }
  if b.kind == "page" or b.kind == "cardTitle" or b.kind == "fieldLabel" or b.kind == "cardBody" or b.kind == "fieldBody" or b.kind == "dialogPanel" or b.kind == "dialogBody" or b.kind == "text" or b.kind == "empty" {
    return ""
  }
  refsKey(eventPath(h.tree, b.path))
}

func editOf(h: Host, id: String): TextEdit {
  match mapGet(h.edits, id) {
    case Some(e) -> e
    case None -> Interact.emptyEdit()
  }
}

/// The wrapped lines of the text area `b` showing `shown`; cached, since measuring is not free.
func areaLinesOf(h: Host, b: Box, shown: String): List[Wrap.VisualLine] {
  val id = idOfBox(h, b)
  val width = b.w - 2.0f32 * h.theme.inputPadding
  match mapGet(h.wraps, id) {
    case Some(entry) -> {
      if entry.value == shown and entry.width == width {
        return entry.lines
      }
    }
    case None -> ()
  }
  val m = h.metrics
  val lines = Wrap.wrapLines(shown, width, { t: String -> m.measure(t, 0, 0.0f32).w })
  if mapKeys(h.wraps).count > 64 {
    h.wraps = newMap()
  }
  h.wraps.add(id, WrapEntry(value = shown, width = width, lines = lines))
  lines
}

// The advance of a text in the body style, trailing spaces included (see `Ui.Native.Paint`'s
// `widthOf`): where a caret or a selection edge after it is drawn.
func advanceOf(m: Metrics, t: String): Float {
  if t.length > 0 and t.endsWith(" ") {
    m.measure(t + "x", 0, 0.0f32).w - m.measure("x", 0, 0.0f32).w
  } else {
    m.measure(t, 0, 0.0f32).w
  }
}

func widthOfText(h: Host): (String) -> Float {
  val m = h.metrics
  { t: String -> advanceOf(m, t) }
}

/// Scrolls the text area `id` so the line the caret is on is in view.
func revealCaret(h: Host, id: String): Unit {
  match findBox(h.page, id, h) {
    case Some(b) -> {
      if b.kind == "textArea" {
        val e = editOf(h, id)
        val lines = areaLinesOf(h, b, b.text)
        val lh = h.metrics.lineHeight(0)
        val view = b.h - 2.0f32 * textAreaPadding
        val row = Wrap.lineIndexOf(lines, e.caret)
        val sy = Interact.clampScroll(Wrap.scrollToRow(e.scrollY, row, lh, view), Wrap.contentHeight(lines, lh), view)
        if sy != e.scrollY {
          h.edits.add(id, e.copy(scrollY = sy))
        }
      }
    }
    case None -> ()
  }
}

func versionOf(h: Host, id: String): Int {
  match mapGet(h.versions, id) {
    case Some(v) -> v
    case None -> 0
  }
}

func gridScrollOf(h: Host, path: List[Int]): Float {
  match mapGet(h.gridScroll, pathKey(path)) {
    case Some(s) -> s
    case None -> 0.0f32
  }
}

// ─── Sending events ───────────────────────────────────────────────────────────
func send(h: Host, path: List[Int], name: String, data: String, inputVersion: Int): Unit {
  match h.instance {
    case None -> ()
    case Some(inst) -> {
      val ev = Ui.Protocol.Event(
        renderVersion = h.renderVersion,
        path = eventPath(h.tree, path),
        name = name,
        data = data,
        inputVersion = inputVersion
      )
      inst.receive(EventMsg(event = ev), InboxOutbox(inbox = h.inbox))
    }
  }
}

func hasEventOn(h: Host, path: List[Int], name: String): Bool {
  match nodeAt(h.tree, path) {
    case Some(WElement(_, _, _, events, _)) -> {
      for e in events {
        if e == name {
          return true
        }
      }
      false
    }
    case _ -> false
  }
}

// ─── Screens and the queue ────────────────────────────────────────────────────
func resetScreenState(h: Host): Unit {
  h.tree = WEmpty
  h.renderVersion = 0
  h.focus = ""
  h.hover = ""
  h.edits = newMap()
  h.versions = newMap()
  h.gridScroll = newMap()
  h.reported = newMap()
  h.pageScroll = 0.0f32
  h.openSelect = ""
  h.composing = ""
}

func closeScreen(h: Host): Unit {
  match h.instance {
    case Some(inst) -> inst.close()
    case None -> ()
  }
  h.instance = None
}

/// Opens the screen for `url`, closing the current one.  `false` when the application has no
/// screen for it (a toast says so and the current screen stays).
pub func navigate(h: Host, url: in String, remember: in Bool): Bool {
  match h.route(url) {
    case None -> {
      toast(h, "No screen for " + url, "error")
      false
    }
    case Some(inst) -> {
      closeScreen(h)
      if remember and h.url.length > 0 {
        h.history.add(h.url)
      }
      resetScreenState(h)
      h.url = url
      h.inbox = Inbox()
      h.instance = Some(value = inst)
      inst.start(InboxOutbox(inbox = h.inbox))
      true
    }
  }
}

func goBack(h: Host): Unit {
  if h.history.count == 0 {
    return
  }
  val last = h.history[h.history.count - 1]
  val kept: List[String] = newList()
  var i = 0
  while i < h.history.count - 1 {
    kept.add(h.history[i])
    i = i + 1
  }
  h.history = kept
  val _ = navigate(h, last, false)
}

func toast(h: Host, message: String, tone: String): Unit {
  h.toasts.add(Toasting(message = message, tone = tone, until = h.now + 4.0f32))
}

/// Applies every message the instance has queued.  Call it once a frame.
pub func pump(h: Host): Unit {
  val texts = h.inbox.take()
  for text in texts {
    match decodeServer(text) {
      case Err(e) -> Console.error("lyric-ui: dropped a malformed message: " + e)
      case Ok(PatchMsg(version, ops)) -> {
        h.tree = applyServer(h.tree, ops, { p: List[Int] -> versionOf(h, refsKey(eventPath(h.tree, p))) })
        h.renderVersion = version
      }
      case Ok(NavigateMsg(url)) -> {
        val _ = navigate(h, url, true)
      }
      case Ok(BackMsg) -> goBack(h)
      case Ok(ToastMsg(message, level)) -> toast(h, message, level)
      case Ok(SessionIdMsg(_)) -> ()
    }
  }
}

// ─── Layout of the current tree ───────────────────────────────────────────────
func layoutNow(h: Host): Box {
  val env = Env(
    theme = h.theme,
    metrics = h.metrics,
    windowWidth = h.width,
    windowHeight = h.height,
    gridScroll = { p: List[Int] -> gridScrollOf(h, p) }
  )
  layoutTree(h.tree, env, h.pageScroll)
}

func findBox(b: Box, id: String, h: Host): Option[Box] {
  if id.length > 0 and idOfBox(h, b) == id {
    return Some(value = b)
  }
  for c in b.children {
    match findBox(c, id, h) {
      case Some(f) -> return Some(value = f)
      case None -> ()
    }
  }
  None
}

func focusedBox(h: Host): Option[Box] {
  if h.focus.length == 0 {
    None
  } else {
    findBox(h.page, h.focus, h)
  }
}

func isTextInput(kind: String): Bool {
  kind == "textInput" or kind == "numberInput" or kind == "dateInput" or kind == "textArea"
}

// ─── Text editing ─────────────────────────────────────────────────────────────
func maxLengthOf(b: Box): Int {
  match parseOptInt(propOf(b.props, "maxLength", "")) {
    case Some(n) -> if n > 0 { n } else { 0 }
    case None -> 0
  }
}

// Commits a change to the focused input: the mirror shows it at once, the session is told, and
// echoes of older edits are ignored from now on.
func applyEdit(h: Host, b: Box, r: Interact.Edited): Unit {
  val id = idOfBox(h, b)
  h.edits.add(id, r.edit)
  if r.changed {
    h.tree = Ui.Diff.applyPatch(h.tree, SetProp(path = b.path, name = "value", value = r.value))
    val v = versionOf(h, id) + 1
    h.versions.add(id, v)
    if hasEventOn(h, b.path, "input") {
      send(h, b.path, "input", r.value, v)
    }
    h.page = layoutNow(h)
  }
}

func typeText(h: Host, text: String): Unit {
  match focusedBox(h) {
    case Some(b) -> if isTextInput(b.kind) and not (propOf(b.props, "readonly", "") == "true") {
      val id = idOfBox(h, b)
      applyEdit(h, b, Interact.insertText(b.text, editOf(h, id), text, maxLengthOf(b)))
      revealCaret(h, id)
    }
    case None -> ()
  }
}

func focusBox(h: Host, b: Box): Unit {
  h.focus = idOfBox(h, b)
  h.composing = ""
  h.openSelect = ""
}

func setCaretFromClick(h: Host, b: Box, x: Float, y: Float, shift: Bool): Unit {
  val id = idOfBox(h, b)
  val e = editOf(h, id)
  val m = h.metrics
  if b.kind == "textArea" {
    val lines = areaLinesOf(h, b, b.text)
    val row = Wrap.rowAtY(lines, y - (b.y + textAreaPadding) + e.scrollY, m.lineHeight(0))
    val pos = Wrap.positionAt(b.text, lines, row, x - (b.x + h.theme.inputPadding), widthOfText(h))
    h.edits.add(id, Interact.moveCaret(b.text, e, pos, shift))
    revealCaret(h, id)
    return
  }
  val local = x - (b.x + h.theme.inputPadding) + e.scrollX
  val pos = Interact.caretAt(b.text, local, { t: String -> advanceOf(m, t) })
  h.edits.add(id, Interact.moveCaret(b.text, e, pos, shift))
}

// ─── Activating controls ──────────────────────────────────────────────────────
func activate(h: Host, b: Box): Unit {
  if b.kind == "link" {
    val href = propOf(b.props, "href", "")
    if hasEventOn(h, b.path, "click") {
      for a in Interact.clickActions(b) {
        send(h, a.path, a.name, a.data, 0)
      }
    } else if href.length > 0 and Interact.hasEvent(b, "click") == false {
      val _ = navigate(h, href, true)
    }
    return
  }
  if b.kind == "select" {
    if h.openSelect == idOfBox(h, b) {
      h.openSelect = ""
    } else {
      h.openSelect = idOfBox(h, b)
      h.selectHover = selectedIndex(h, b)
    }
    return
  }
  for a in Interact.clickActions(b) {
    send(h, a.path, a.name, a.data, 0)
  }
}

func optionNodes(h: Host, b: Box): List[WireNode] {
  match nodeAt(h.tree, b.path) {
    case Some(WElement(_, _, _, _, children)) -> children
    case _ -> newList()
  }
}

func optionValue(n: WireNode): String {
  match n {
    case WElement(_, _, props, _, _) -> propOf(props, "value", "")
    case _ -> ""
  }
}

func selectedIndex(h: Host, b: Box): Int {
  val current = propOf(b.props, "value", "")
  var i = 0
  for n in optionNodes(h, b) {
    if optionValue(n) == current {
      return i
    }
    i = i + 1
  }
  0
}

func chooseOption(h: Host, b: Box, index: Int): Unit {
  val nodes = optionNodes(h, b)
  if index >= 0 and index < nodes.count {
    val v = optionValue(nodes[index])
    h.tree = Ui.Diff.applyPatch(h.tree, SetProp(path = b.path, name = "value", value = v))
    if hasEventOn(h, b.path, "change") {
      send(h, b.path, "change", v, 0)
    }
  }
  h.openSelect = ""
}

func submitForm(h: Host, from: Box): Unit {
  val chain = Interact.ancestorsOf(h.page, from.path)
  var i = chain.count - 1
  while i >= 0 {
    if chain[i].kind == "form" and Interact.hasEvent(chain[i], "submit") {
      send(h, chain[i].path, "submit", "", 0)
      return
    }
    i = i - 1
  }
}

// ─── Window events ────────────────────────────────────────────────────────────
val keyBackspace: Int = 8

val keyTab: Int = 9

val keyReturn: Int = 13

val keyEscape: Int = 27

val keySpace: Int = 32

val keyDelete: Int = 127

val keyRight: Int = 1073741903

val keyLeft: Int = 1073741904

val keyDown: Int = 1073741905

val keyUp: Int = 1073741906

val keyHome: Int = 1073741898

val keyEnd: Int = 1073741901

val keyPageUp: Int = 1073741899

val keyPageDown: Int = 1073741902

func hasShift(mods: Int): Bool {
  mods.and(3) != 0
}

func hasCommand(mods: Int): Bool {
  mods.and(0x00C0).or(mods.and(0x0C00)) != 0
}

func scrollGrid(h: Host, body: Box, delta: Float): Unit {
  val key = pathKey(body.path)
  val current = gridScrollOf(h, body.path)
  h.gridScroll.add(key, Interact.clampScroll(current + delta, body.contentHeight, body.h))
}

func gridBodyAt(h: Host, x: Float, y: Float): Option[Box] {
  match Interact.hitTest(h.page, x, y) {
    case Some(b) -> {
      if b.kind == "gridRow" or b.kind == "gridBody" {
        val chain = Interact.ancestorsOf(h.page, if b.kind == "gridBody" { b.path } else { parentPath(b.path) })
        var i = chain.count - 1
        while i >= 0 {
          if chain[i].kind == "dataGrid" {
            for c in chain[i].children {
              if c.kind == "gridBody" {
                return Some(value = c)
              }
            }
          }
          i = i - 1
        }
      }
      None
    }
    case None -> None
  }
}

func onMouseDown(h: Host, x: Float, y: Float, shift: Bool, clicks: Int): Unit {
  h.mouseX = x
  h.mouseY = y
  if h.openSelect.length > 0 {
    match findBox(h.page, h.openSelect, h) {
      case Some(sel) -> {
        val rowH = h.theme.controlHeight
        val top = sel.y + sel.h + 2.0f32
        if x >= sel.x and x < sel.x + sel.w and y >= top {
          chooseOption(h, sel, ((y - top) / rowH).toInt())
          return
        }
        h.openSelect = ""
        if y >= sel.y and y < sel.y + sel.h and x >= sel.x and x < sel.x + sel.w {
          return
        }
      }
      case None -> {
        h.openSelect = ""
      }
    }
  }
  match Interact.hitTest(h.page, x, y) {
    case None -> {
      h.focus = ""
      h.composing = ""
    }
    case Some(b) -> {
      if b.kind == "dialog" {
        return
      }
      if b.kind == "colheader" {
        h.focus = idOfBox(h, b)
        send(h, parentPath(b.path), "sort", b.key, 0)
        return
      }
      if b.kind == "gridBody" {
        focusBox(h, b)
        return
      }
      if isTextInput(b.kind) {
        focusBox(h, b)
        setCaretFromClick(h, b, x, y, shift)
        h.dragging = idOfBox(h, b)
        if clicks >= 3 {
          if b.kind == "textArea" {
            h.edits.add(h.dragging, Interact.paragraphAt(b.text, editOf(h, h.dragging).caret))
          } else {
            h.edits.add(h.dragging, Interact.selectAll(b.text, editOf(h, h.dragging)))
          }
          h.dragging = ""
        } else if clicks == 2 {
          val c = editOf(h, h.dragging)
          h.edits.add(h.dragging, Interact.wordAt(b.text, c.caret))
          h.dragging = ""
        }
        return
      }
      if b.focusable {
        focusBox(h, b)
      }
      activate(h, b)
    }
  }
}

func moveRowFocus(h: Host, current: Box, delta: Int): Unit {
  val chain = Interact.ancestorsOf(h.page, parentPath(current.path))
  var i = chain.count - 1
  while i >= 0 {
    if chain[i].kind == "dataGrid" {
      for c in chain[i].children {
        if c.kind == "gridBody" {
          var at = -1
          var k = 0
          for r in c.children {
            if idOfBox(h, r) == h.focus {
              at = k
            }
            k = k + 1
          }
          val next = at + delta
          if next >= 0 and next < c.children.count {
            h.focus = idOfBox(h, c.children[next])
            val row = c.children[next]
            if row.y < c.y {
              scrollGrid(h, c, row.y - c.y)
            } else if row.y + row.h > c.y + c.h {
              scrollGrid(h, c, row.y + row.h - c.y - c.h)
            }
          }
        }
      }
      return
    }
    i = i - 1
  }
}

func onKey(h: Host, key: Int, mods: Int): Unit {
  val shift = hasShift(mods)
  val cmd = hasCommand(mods)
  if key == keyTab {
    val order = Interact.focusOrder(h.page)
    match Interact.nextFocus(order, h.focus, { b: Box -> idOfBox(h, b) }, shift) {
      case Some(b) -> focusBox(h, b)
      case None -> ()
    }
    return
  }
  if key == keyEscape {
    h.openSelect = ""
    return
  }
  match focusedBox(h) {
    case None -> {
      if key == keyPageDown or key == keyDown {
        h.pageScroll = clampPage(h, h.pageScroll + (if key == keyPageDown { h.height * 0.9f32 } else { 40.0f32 }))
      } else if key == keyPageUp or key == keyUp {
        h.pageScroll = clampPage(h, h.pageScroll - (if key == keyPageUp { h.height * 0.9f32 } else { 40.0f32 }))
      }
    }
    case Some(b) -> {
      if isTextInput(b.kind) {
        onTextKey(h, b, key, shift, cmd)
        revealCaret(h, idOfBox(h, b))
      } else if b.kind == "select" {
        onSelectKey(h, b, key)
      } else if b.kind == "gridRow" {
        if key == keyDown {
          moveRowFocus(h, b, 1)
        } else if key == keyUp {
          moveRowFocus(h, b, -1)
        } else if key == keyReturn or key == keySpace {
          activate(h, b)
        }
      } else if b.kind == "gridBody" {
        if key == keyDown {
          if b.children.count > 0 {
            h.focus = idOfBox(h, b.children[0])
          }
        } else if key == keyPageDown {
          scrollGrid(h, b, b.h)
        } else if key == keyPageUp {
          scrollGrid(h, b, 0.0f32 - b.h)
        }
      } else if b.kind == "colheader" {
        if key == keyReturn or key == keySpace {
          send(h, parentPath(b.path), "sort", b.key, 0)
        }
      } else if key == keyReturn or key == keySpace {
        activate(h, b)
      }
    }
  }
}

// The wheel over a text area taller than its box scrolls the text; false when it does not
// (no such area under the pointer, or it is already at that end), so the page scrolls instead.
func scrollTextArea(h: Host, dy: Float): Bool {
  match Interact.hitTest(h.page, h.mouseX, h.mouseY) {
    case Some(b) -> {
      if b.kind != "textArea" {
        return false
      }
      val id = idOfBox(h, b)
      val e = editOf(h, id)
      val lh = h.metrics.lineHeight(0)
      val view = b.h - 2.0f32 * textAreaPadding
      val content = Wrap.contentHeight(areaLinesOf(h, b, b.text), lh)
      val next = Interact.clampScroll(e.scrollY - dy * 48.0f32, content, view)
      if next == e.scrollY {
        return false
      }
      h.edits.add(id, e.copy(scrollY = next))
      true
    }
    case None -> false
  }
}

func clampPage(h: Host, v: Float): Float {
  val most = if h.page.contentHeight > h.height { h.page.contentHeight - h.height } else { 0.0f32 }
  if v < 0.0f32 {
    0.0f32
  } else if v > most {
    most
  } else {
    v
  }
}

func onSelectKey(h: Host, b: Box, key: Int): Unit {
  val n = optionNodes(h, b).count
  if key == keyReturn or key == keySpace {
    if h.openSelect == idOfBox(h, b) {
      chooseOption(h, b, h.selectHover)
    } else {
      activate(h, b)
    }
  } else if key == keyDown or key == keyUp {
    val delta = if key == keyDown { 1 } else { -1 }
    if h.openSelect == idOfBox(h, b) {
      val next = h.selectHover + delta
      if next >= 0 and next < n {
        h.selectHover = next
      }
    } else {
      val next = selectedIndex(h, b) + delta
      if next >= 0 and next < n {
        chooseOption(h, b, next)
      }
    }
  }
}

func onTextKey(h: Host, b: Box, key: Int, shift: Bool, cmd: Bool): Unit {
  val id = idOfBox(h, b)
  val e = editOf(h, id)
  val value = b.text
  val readonly = propOf(b.props, "readonly", "") == "true"
  if cmd and (key == 97 or key == 99 or key == 120 or key == 118) {
    if key == 97 {
      h.edits.add(id, Interact.selectAll(value, e))
    } else if key == 99 or key == 120 {
      val selected = Interact.selectedText(value, e)
      if selected.length > 0 {
        val _ = Window.setClipboardText(selected)
        if key == 120 and not readonly {
          applyEdit(h, b, Interact.backspace(value, e))
        }
      }
    } else if not readonly {
      match Window.clipboardText() {
        case Some(t) -> typeText(h, t)
        case None -> ()
      }
    }
    return
  }
  if key == keyBackspace {
    if not readonly {
      applyEdit(h, b, Interact.backspace(value, e))
    }
  } else if key == keyDelete {
    if not readonly {
      applyEdit(h, b, Interact.deleteForward(value, e))
    }
  } else if key == keyLeft {
    if b.kind == "textArea" {
      h.edits.add(id, Interact.stepVisualCaret(value, areaLinesOf(h, b, value), e, -1, shift, widthOfText(h)))
    } else {
      h.edits.add(id, Interact.stepCaret(value, e, -1, shift))
    }
  } else if key == keyRight {
    if b.kind == "textArea" {
      h.edits.add(id, Interact.stepVisualCaret(value, areaLinesOf(h, b, value), e, 1, shift, widthOfText(h)))
    } else {
      h.edits.add(id, Interact.stepCaret(value, e, 1, shift))
    }
  } else if key == keyHome {
    if b.kind == "textArea" and not cmd {
      h.edits.add(id, Interact.moveToLineEdge(value, areaLinesOf(h, b, value), e, false, shift))
    } else {
      h.edits.add(id, Interact.moveCaret(value, e, 0, shift))
    }
  } else if key == keyEnd {
    if b.kind == "textArea" and not cmd {
      h.edits.add(id, Interact.moveToLineEdge(value, areaLinesOf(h, b, value), e, true, shift))
    } else {
      h.edits.add(id, Interact.moveCaret(value, e, Interact.cpCount(value), shift))
    }
  } else if b.kind == "textArea" and (key == keyUp or key == keyDown or key == keyPageUp or key == keyPageDown) {
    val lh = h.metrics.lineHeight(0)
    val page = (b.h - 2.0f32 * textAreaPadding) / lh
    val rows = if page >= 2.0f32 { page.toInt() - 1 } else { 1 }
    val delta = if key == keyUp { -1 } else if key == keyDown { 1 } else if key == keyPageUp { 0 - rows } else { rows }
    h.edits.add(id, Interact.moveVertical(value, areaLinesOf(h, b, value), e, delta, shift, widthOfText(h)))
  } else if key == keyReturn {
    if b.kind == "textArea" {
      if not readonly {
        typeText(h, "\n")
      }
    } else {
      submitForm(h, b)
    }
  }
}

/// Handles one window event: the whole of the user's interaction with the host.
pub func handle(h: Host, e: Window.Event): Unit {
  match e {
    case Quit -> {
      h.quit = true
    }
    case WindowCloseRequested(_) -> {
      h.quit = true
    }
    case WindowResized(_, w, ht) -> ()
    case KeyDown(_, key, _, mods, _) -> onKey(h, key, mods)
    case KeyUp(_, _, _, _) -> ()
    case TextInput(_, text) -> {
      h.composing = ""
      typeText(h, text)
    }
    case TextEditing(_, text, _, _) -> {
      h.composing = text
    }
    case MouseMotion(_, x, y, _, _) -> {
      h.mouseX = x
      h.mouseY = y
      if h.dragging.length > 0 {
        match findBox(h.page, h.dragging, h) {
          case Some(b) -> setCaretFromClick(h, b, x, y, true)
          case None -> {
            h.dragging = ""
          }
        }
      }
      h.hover = match Interact.hitTest(h.page, x, y) { case Some(b) -> idOfBox(h, b); case None -> "" }
      if h.openSelect.length > 0 {
        match findBox(h.page, h.openSelect, h) {
          case Some(sel) -> {
            val i = ((y - (sel.y + sel.h + 2.0f32)) / h.theme.controlHeight).toInt()
            if y >= sel.y + sel.h + 2.0f32 and i < optionNodes(h, sel).count {
              h.selectHover = i
            }
          }
          case None -> ()
        }
      }
    }
    case MouseButtonDown(_, button, x, y, clicks) -> if button == 1 { onMouseDown(h, x, y, false, clicks) }
    case MouseButtonUp(_, _, _, _, _) -> {
      h.dragging = ""
    }
    case MouseWheel(_, dx, dy) -> {
      match gridBodyAt(h, h.mouseX, h.mouseY) {
        case Some(body) -> scrollGrid(h, body, 0.0f32 - dy * 48.0f32)
        case None -> {
          if not scrollTextArea(h, dy) {
            h.pageScroll = clampPage(h, h.pageScroll - dy * 48.0f32)
          }
        }
      }
    }
    case Other(_) -> ()
  }
}

// ─── A frame ──────────────────────────────────────────────────────────────────
// Asks the session for the rows a data grid shows but has not loaded.
func reportViewports(h: Host, b: Box): Unit {
  if b.kind == "gridBody" {
    val gridProps = match nodeAt(h.tree, b.path) { case Some(WElement(_, _, props, _, _)) -> props; case _ -> newList() }
    val scroll = gridScrollOf(h, b.path)
    match Interact.viewportNeeded(gridProps, b.children.count, scroll, b.h) {
      case Some(data) -> {
        val key = pathKey(b.path)
        val stamp = data + "@" + propOf(gridProps, "firstRow", "0") + "+" + b.children.count.toString()
        val already = match mapGet(h.reported, key) { case Some(s) -> s == stamp; case None -> false }
        if not already and hasEventOn(h, b.path, "viewport") {
          h.reported.add(key, stamp)
          send(h, b.path, "viewport", data, 0)
        }
      }
      case None -> ()
    }
  }
  for c in b.children {
    reportViewports(h, c)
  }
}

func selectChoices(h: Host, b: Box): List[String] {
  val labels: List[String] = newList()
  for n in optionNodes(h, b) {
    labels.add(textOfWire(n))
  }
  labels
}

/// Lays the tree out, reports what the session still needs (grid rows), and draws one frame into
/// the painter, which the caller has started with `Draw.beginFrame` and `Draw.setScale`.
pub func renderFrame(h: Host, p: Draw.Painter): Unit {
  h.page = layoutNow(h)
  h.pageScroll = clampPage(h, h.pageScroll)
  reportViewports(h, h.page)
  val fontsRef = h.fonts
  val ctx = PaintCtx(
    theme = h.theme,
    fonts = fontsRef,
    focusId = h.focus,
    hoverId = h.hover,
    idOf = { b: Box -> idOfBox(h, b) },
    editOf = { id: String -> editOf(h, id) },
    time = h.now,
    composing = h.composing,
    openSelect = h.openSelect,
    scale = h.scale,
    areaLines = { b: Box, shown: String -> areaLinesOf(h, b, shown) }
  )
  paintPage(h.page, p, ctx)
  if h.openSelect.length > 0 {
    match findBox(h.page, h.openSelect, h) {
      case Some(sel) -> paintSelectPopup(sel, selectChoices(h, sel), h.selectHover, p, ctx)
      case None -> ()
    }
  }
  val live: List[Toasting] = newList()
  for t in h.toasts {
    if t.until > h.now {
      live.add(t)
    }
  }
  h.toasts = live
  val messages: List[String] = newList()
  val tones: List[String] = newList()
  for t in live {
    messages.add(t.message)
    tones.add(t.tone)
  }
  paintToasts(messages, tones, h.width, h.height, p, ctx)
}

/// The caret's rectangle in logical pixels when a text input has focus, for the input method.
pub func caretArea(h: Host): Option[Ui.Native.Layout.Box] {
  match focusedBox(h) {
    case Some(b) -> {
      if b.kind == "textArea" {
        val e = editOf(h, idOfBox(h, b))
        val lines = areaLinesOf(h, b, b.text)
        val lh = h.metrics.lineHeight(0)
        val row = Wrap.lineIndexOf(lines, e.caret)
        val cx = b.x + h.theme.inputPadding + Wrap.offsetInRow(b.text, lines, row, e.caret, widthOfText(h))
        val cy = b.y + textAreaPadding - e.scrollY + row.toFloat() * lh
        Some(value = b.copy(x = cx, y = cy, w = 1.0f32, h = lh))
      } else if isTextInput(b.kind) {
        Some(value = b)
      } else {
        None
      }
    }
    case None -> None
  }
}

// ─── The window ───────────────────────────────────────────────────────────────
func surfaceFor(d: Gpu.Device, w: Window.Window): Result[Gpu.Surface, String] {
  match Window.nativeWindow(w) {
    case X11(display, window) -> Gpu.createXlibSurface(d, display, window)
    case Wayland(display, surface) -> Gpu.createWaylandSurface(d, display, surface)
    case Win32(hwnd, instance) -> Gpu.createWindowsSurface(d, instance, hwnd)
    case _ -> Err(error = "this window system has no GPU surface support yet")
  }
}

func fail(message: String): Int {
  Console.println("FAIL: " + message)
  1
}

func scaleOf(win: Window.Window): Float {
  val logical = Window.windowSize(win)
  val pixels = Window.pixelSize(win)
  if logical.width > 0 {
    pixels.width.toFloat() / logical.width.toFloat()
  } else {
    1.0f32
  }
}

func loopWindow(d: Gpu.Device, win: Window.Window, surface0: Gpu.Surface, h: Host): Int {
  var surface = surface0
  val painter = match Draw.newPainter(d, surface.format) { case Ok(p) -> p; case Err(m) -> return fail(m) }
  Draw.setScale(painter, h.scale)
  Window.startTextInput(win)
  val started = Time.nowEpochMillis()
  var failure = ""
  var announced = false
  while not h.quit and failure == "" {
    h.now = (Time.nowEpochMillis() - started).toFloat() / 1000.0f32
    var polling = true
    while polling {
      match Window.pollEvent() {
        case None -> {
          polling = false
        }
        case Some(e) -> {
          match e {
            case WindowResized(_, _, _) -> {
              val sz = Window.windowSize(win)
              h.width = sz.width.toFloat()
              h.height = sz.height.toFloat()
              val px = Window.pixelSize(win)
              match Gpu.configureSurface(d, surface, px.width, px.height) {
                case Ok(s) -> {
                  surface = s
                }
                case Err(m) -> {
                  failure = m
                }
              }
            }
            case _ -> ()
          }
          handle(h, e)
        }
      }
    }
    pump(h)
    match Gpu.acquireFrame(d, surface) {
      case Err(_) -> {
        val px = Window.pixelSize(win)
        match Gpu.configureSurface(d, surface, px.width, px.height) {
          case Ok(s) -> {
            surface = s
          }
          case Err(m) -> {
            failure = m
          }
        }
        Window.delayNanos(16000000)
      }
      case Ok(target) -> {
        Draw.beginFrame(painter, target.width, target.height)
        renderFrame(h, painter)
        match caretArea(h) {
          case Some(b) -> Window.setTextInputArea(win, b.x.toInt(), b.y.toInt(), b.w.toInt(), b.h.toInt(), 0)
          case None -> ()
        }
        match Draw.finish(painter, target, Draw.rgb(h.theme.bg.r, h.theme.bg.g, h.theme.bg.b)) {
          case Err(m) -> {
            Gpu.discardFrame(target)
            failure = m
          }
          case Ok(_) -> match Gpu.presentFrame(surface, target) {
            case Ok(_) -> {
              if not announced {
                announced = true
                Console.println("presented")
              }
            }
            case Err(m) -> {
              failure = m
            }
          }
        }
      }
    }
  }
  Window.stopTextInput(win)
  Draw.releasePainter(painter)
  if failure.length > 0 then fail(failure) else 0
}

/// Runs the application in a window until it is closed.  `route(url)` is the same function the
/// web and desktop hosts take; the first screen is `cfg.startPath`.  Returns a process exit code.
pub func run(cfg: NativeConfig, route: (String) -> Option[Instance]): Int {
  match Window.init(Window.initVideo) {
    case Err(m) -> return fail(m)
    case Ok(_) -> ()
  }
  val win = match Window.createWindow(cfg.title, cfg.width, cfg.height, true) {
    case Ok(w) -> w
    case Err(m) -> return fail(m)
  }
  Window.show(win)
  val lib = match Text.initText() { case Ok(l) -> l; case Err(m) -> return fail(m) }
  val scale = scaleOf(win)
  val fonts = match openFonts(lib, cfg, scale) { case Ok(f) -> f; case Err(m) -> return fail(m) }
  val size = Window.windowSize(win)
  val host = openHost(cfg, route, fonts, scale, size.width.toFloat(), size.height.toFloat())
  if not navigate(host, cfg.startPath, false) {
    return fail("the application has no screen for " + cfg.startPath)
  }
  val body: (Gpu.Device) -> Int = { d: Gpu.Device ->
    match surfaceFor(d, win) {
      case Err(m) -> fail(m)
      case Ok(created) -> {
        val px = Window.pixelSize(win)
        match Gpu.configureSurface(d, created, px.width, px.height) {
          case Err(m) -> fail(m)
          case Ok(surface) -> {
            val rc = loopWindow(d, win, surface, host)
            Gpu.releaseSurface(surface)
            rc
          }
        }
      }
    }
  }
  val rc = match Gpu.withDevice(body) { case Err(m) -> fail(m); case Ok(code) -> code }
  closeScreen(host)
  closeFonts(fonts)
  Text.closeText(lib)
  Window.destroyWindow(win)
  Window.quit()
  rc
}

// ─── Headless ─────────────────────────────────────────────────────────────────
/// A host with no window: a `width` by `height` frame at `scale` that scripted events can drive
/// and that draws into an offscreen target.  `close` it when done.
pub record Headless {
  host: Host
  lib: Text.TextLib
  device: Gpu.Device
  painter: Draw.Painter
  target: Gpu.RenderTarget
}

/// Runs `body` with a headless host showing `url`.  `Err` when the GPU, fonts or first screen
/// cannot be set up.
pub func withHeadless[T](
  cfg: NativeConfig,
  route: (String) -> Option[Instance],
  url: String,
  width: Int,
  height: Int,
  scale: Float,
  body: (Headless) -> T,
): Result[T, String] {
  val lib = match Text.initText() { case Ok(l) -> l; case Err(m) -> return Err(error = m) }
  val fonts = match openFonts(lib, cfg, scale) {
    case Ok(f) -> f
    case Err(m) -> {
      Text.closeText(lib)
      return Err(error = m)
    }
  }
  val inner: (Gpu.Device) -> Result[T, String] = { d: Gpu.Device ->
    val px = (width.toFloat() * scale).toInt()
    val py = (height.toFloat() * scale).toInt()
    val target = Gpu.createRenderTarget(d, px, py)
    match Draw.newPainter(d, Gpu.formatRgba8) {
      case Err(m) -> Err(error = m)
      case Ok(painter) -> {
        Draw.setScale(painter, scale)
        val host = openHost(cfg, route, fonts, scale, width.toFloat(), height.toFloat())
        if not navigate(host, url, false) {
          Draw.releasePainter(painter)
          Gpu.releaseRenderTarget(target)
          Err(error = "the application has no screen for " + url)
        } else {
          val r = body(Headless(host = host, lib = lib, device = d, painter = painter, target = target))
          closeScreen(host)
          Draw.releasePainter(painter)
          Gpu.releaseRenderTarget(target)
          Ok(value = r)
        }
      }
    }
  }
  val outcome = Gpu.withDevice(inner)
  closeFonts(fonts)
  Text.closeText(lib)
  match outcome {
    case Ok(r) -> r
    case Err(m) -> Err(error = m)
  }
}

/// Waits until the instance has been quiet (no new message) for `quietMs`, applying what arrives,
/// or `timeoutMs` has passed: for a screen whose effects load data.
pub func settle(hl: Headless, quietMs: Int, timeoutMs: Int): Unit {
  val h = hl.host
  var waited = 0
  var quiet = 0
  while quiet < quietMs and waited < timeoutMs {
    val before = h.renderVersion
    pump(h)
    if h.renderVersion != before {
      quiet = 0
    } else {
      quiet = quiet + 10
    }
    Window.delayNanos(10000000)
    waited = waited + 10
  }
}

/// Feeds `events` to the host as if the user had produced them, then applies what the session
/// answers.
pub func script(hl: Headless, events: List[Window.Event]): Unit {
  for e in events {
    handle(hl.host, e)
  }
  settle(hl, 60, 2000)
}

/// Draws a frame and returns its pixels (RGBA8, top row first).
pub func snapshot(hl: Headless): Result[buffer[Byte], String] {
  val h = hl.host
  h.page = layoutNow(h)
  Draw.beginFrame(hl.painter, hl.target.width, hl.target.height)
  renderFrame(h, hl.painter)
  match Draw.finish(hl.painter, hl.target, Draw.rgb(h.theme.bg.r, h.theme.bg.g, h.theme.bg.b)) {
    case Err(m) -> Err(error = m)
    case Ok(_) -> Gpu.readPixels(hl.device, hl.target)
  }
}

/// The text of the current tree, for assertions: every text node and button label in order.
pub func screenText(hl: Headless): String {
  textOfTree(hl.host.tree)
}

func textOfTree(n: WireNode): String {
  match n {
    case WText(v) -> v + "\n"
    case WEmpty -> ""
    case WElement(kind, _, props, _, children) -> {
      var s = ""
      if kind == "button" {
        s = "[" + propOf(props, "label", "") + "]\n"
      } else if kind == "textInput" or kind == "numberInput" or kind == "dateInput" or kind == "textArea" {
        s = "<" + propOf(props, "value", "") + ">\n"
      } else if kind == "dataGrid" {
        s = "grid " + propOf(props, "label", "") + " rows=" + propOf(props, "rowCount", "0") + "\n"
      }
      for c in children {
        s = s + textOfTree(c)
      }
      s
    }
  }
}

/// The boxes of the last frame, for finding where to click in a script.
pub func boxes(hl: Headless): Box {
  hl.host.page
}

/// Finds the first box of `kind` whose text (or label) is `text`.
pub func findByText(hl: Headless, kind: String, text: String): Option[Box] {
  findKind(hl.host.page, kind, text)
}

func findKind(b: Box, kind: String, text: String): Option[Box] {
  if b.kind == kind and (b.text == text or propOf(b.props, "label", "") == text) {
    return Some(value = b)
  }
  for c in b.children {
    match findKind(c, kind, text) {
      case Some(f) -> return Some(value = f)
      case None -> ()
    }
  }
  None
}

/// The first box of `kind` in the last frame.
pub func firstOfKind(hl: Headless, kind: String): Option[Box] {
  firstKind(hl.host.page, kind)
}

func firstKind(b: Box, kind: String): Option[Box] {
  if b.kind == kind {
    return Some(value = b)
  }
  for c in b.children {
    match firstKind(c, kind) {
      case Some(f) -> return Some(value = f)
      case None -> ()
    }
  }
  None
}

/// The caret of the focused input in code points, or -1 when nothing is focused.
pub func caretOf(hl: Headless): Int {
  match focusedBox(hl.host) {
    case Some(b) -> editOf(hl.host, idOfBox(hl.host, b)).caret
    case None -> 0 - 1
  }
}

/// The number of visual lines the text area `area` shows its text in.
pub func areaRows(hl: Headless, area: Box): Int {
  areaLinesOf(hl.host, area, area.text).count
}

/// The visual line the caret of the focused text area is on.
pub func caretRow(hl: Headless): Int {
  match focusedBox(hl.host) {
    case Some(b) -> Wrap.lineIndexOf(areaLinesOf(hl.host, b, b.text), editOf(hl.host, idOfBox(hl.host, b)).caret)
    case None -> 0 - 1
  }
}

/// The height of one line of text in a text area, in logical pixels.
pub func areaLineHeight(hl: Headless): Float {
  hl.host.metrics.lineHeight(0)
}

/// The vertical scroll of the text area `area`, in logical pixels.
pub func areaScroll(hl: Headless, area: Box): Float {
  editOf(hl.host, idOfBox(hl.host, area)).scrollY
}

/// The composition text an input method is currently holding in the focused input ("" when none).
pub func composing(hl: Headless): String {
  hl.host.composing
}

/// The messages of the toasts now showing.
pub func toastTexts(hl: Headless): List[String] {
  val acc: List[String] = newList()
  for t in hl.host.toasts {
    acc.add(t.message)
  }
  acc
}
