//! access.l - Ui.Native.Access: the accessibility tree of the native host (docs/65 §13.3, docs/67 G10).
//!
//! The web and desktop hosts get ARIA from the browser; the native host draws everything itself,
//! so it publishes a tree of accessible nodes to the platform (AccessKit, issue #8430).  This
//! package is the host-free half: it maps the laid-out boxes of `Ui.Native.Layout` to roles,
//! names, values, states and actions exactly as `runtime/ui.js` assigns ARIA in the browser, and
//! it knows nothing about a window or a platform adapter, so it is tested on every target.
//!
//! `buildTree` flattens a page into a pre-order list of `AccessNode`s with child id lists (the
//! shape platform trees take).  Node ids are the host's stable ids for boxes (`idOf`, the keyed
//! event path), with a path-derived fallback for boxes the host does not identify.  `diffTrees`
//! turns two trees into the nodes that changed and the ids that disappeared, so an adapter sends
//! only what moved.  `resolveRequest` turns an assistive technology's request (focus, click, set
//! value, scroll into view) into the same actions the mouse and keyboard produce.
//!
//! Layout helper boxes with no meaning of their own (columns, rows, card bodies, dialog panels,
//! a data grid's scrolling body) are flattened away, field labels and errors become the control's
//! name and description, and a dialog is modal.
@pure
package Ui.Native.Access

import Std.Core
import Std.Collections
import Std.String
import Std.Parse.{parseOptInt}
import Ui.Native.Layout.{Box, propOf}
import Ui.Native.Interact.{TextEdit, Action, clickActions, hasEvent}

pub enum Role {
  case RoleWindow
  case RoleGroup
  case RoleForm
  case RoleHeading
  case RoleParagraph
  case RoleLabel
  case RoleStatus
  case RoleAlert
  case RoleProgress
  case RoleButton
  case RoleLink
  case RoleTextInput
  case RolePasswordInput
  case RoleMultilineInput
  case RoleSpinButton
  case RoleCheckBox
  case RoleComboBox
  case RoleTable
  case RoleGrid
  case RoleRow
  case RoleCell
  case RoleColumnHeader
  case RoleDialog
}

/// The ARIA-style name of a role, as used in tests and diagnostics.
pub func roleName(r: in Role): String {
  match r {
    case RoleWindow -> "window"
    case RoleGroup -> "group"
    case RoleForm -> "form"
    case RoleHeading -> "heading"
    case RoleParagraph -> "paragraph"
    case RoleLabel -> "label"
    case RoleStatus -> "status"
    case RoleAlert -> "alert"
    case RoleProgress -> "progressbar"
    case RoleButton -> "button"
    case RoleLink -> "link"
    case RoleTextInput -> "textbox"
    case RolePasswordInput -> "password"
    case RoleMultilineInput -> "textbox-multiline"
    case RoleSpinButton -> "spinbutton"
    case RoleCheckBox -> "checkbox"
    case RoleComboBox -> "combobox"
    case RoleTable -> "table"
    case RoleGrid -> "grid"
    case RoleRow -> "row"
    case RoleCell -> "cell"
    case RoleColumnHeader -> "columnheader"
    case RoleDialog -> "dialog"
  }
}

/// The checked state of a node: absent for nodes that are not toggles.
pub enum Toggled {
  case NotToggle
  case Unchecked
  case Checked
}

pub func toggledName(t: in Toggled): String {
  match t {
    case NotToggle -> ""
    case Unchecked -> "false"
    case Checked -> "true"
  }
}

/// One accessible node.  Zero or empty means "not applicable"; `selAnchor` and `selCaret` are
/// code point offsets into `value` and negative when the node is not an input with a selection.
/// The rectangle is in window pixels.  `actions` names what an assistive technology may ask the
/// node to do: `focus`, `click`, `setValue`.
pub record AccessNode {
  id: String
  role: Role
  name: String
  description: String
  value: String
  level: Int
  toggled: Toggled
  expanded: Option[Bool]
  live: String
  modal: Bool
  disabled: Bool
  invalid: Bool
  required: Bool
  readOnly: Bool
  sort: String
  rowCount: Int
  colCount: Int
  rowIndex: Int
  colIndex: Int
  selAnchor: Int
  selCaret: Int
  x: Float
  y: Float
  w: Float
  h: Float
  actions: List[String]
  childIds: List[String]
}

/// A whole tree: `nodes` in pre-order (parents before children, `rootId` first), and the id of
/// the node that has keyboard focus (the root when nothing does).
pub record AccessTree {
  rootId: String
  focus: String
  nodes: List[AccessNode]
}

/// What the host knows that boxes do not: the focused id, the select whose popup is open ("" for
/// none) and the text edit state (caret and anchor) of an input id.
pub record AccessState {
  focusId: String
  openSelect: String
  edit: (String) -> Option[TextEdit]
}

pub func rootId(): String {
  "root"
}

// ─── Building ─────────────────────────────────────────────────────────────────
record Ctx {
  label: String
  description: String
  invalid: Bool
}

record Built {
  top: List[String]
  all: List[AccessNode]
}

func noCtx(): Ctx {
  Ctx(label = "", description = "", invalid = false)
}

func pathText(path: List[Int]): String {
  var s = ""
  var first = true
  for p in path {
    if not first {
      s = s + "."
    }
    s = s + p.toString()
    first = false
  }
  s
}

func idFor(b: Box, idOf: (Box) -> String, parentId: String): String {
  val raw = idOf(b)
  val base = if raw.length > 0 { raw } else { "n:" + pathText(b.path) + ":" + b.kind }
  if base == parentId {
    base + "/inner"
  } else {
    base
  }
}

func flagOf(b: Box, name: String): Bool {
  propOf(b.props, name, "") == "true"
}

func baseNode(id: String, role: Role, name: String, b: Box): AccessNode {
  AccessNode(
    id = id,
    role = role,
    name = name,
    description = "",
    value = "",
    level = 0,
    toggled = NotToggle,
    expanded = None,
    live = "",
    modal = false,
    disabled = false,
    invalid = false,
    required = false,
    readOnly = false,
    sort = "",
    rowCount = 0,
    colCount = 0,
    rowIndex = 0,
    colIndex = 0,
    selAnchor = -1,
    selCaret = -1,
    x = b.x,
    y = b.y,
    w = b.w,
    h = b.h,
    actions = newList(),
    childIds = newList()
  )
}

func actionList(names: List[String]): List[String] {
  names
}

func concatIds(a: List[String], b: List[String]): List[String] {
  val r: List[String] = newList()
  for x in a {
    r.add(x)
  }
  for x in b {
    r.add(x)
  }
  r
}

func concatNodes(a: List[AccessNode], b: List[AccessNode]): List[AccessNode] {
  val r: List[AccessNode] = newList()
  for x in a {
    r.add(x)
  }
  for x in b {
    r.add(x)
  }
  r
}

func emptyBuilt(): Built {
  Built(top = newList(), all = newList())
}

func leaf(n: AccessNode): Built {
  val top: List[String] = newList()
  top.add(n.id)
  val all: List[AccessNode] = newList()
  all.add(n)
  Built(top = top, all = all)
}

/// `n` as the parent of the nodes `kids` built.
func parentOf(n: AccessNode, kids: Built): Built {
  val top: List[String] = newList()
  top.add(n.id)
  val all: List[AccessNode] = newList()
  all.add(n.copy(childIds = kids.top))
  for k in kids.all {
    all.add(k)
  }
  Built(top = top, all = all)
}

func buildChildren(
  boxes: List[Box],
  st: AccessState,
  idOf: (Box) -> String,
  parentId: String,
  ctx: Ctx,
  firstColumn: Int,
): Built {
  var top: List[String] = newList()
  var all: List[AccessNode] = newList()
  var col = firstColumn
  var used = false
  for c in boxes {
    // The field's label and errors belong to its first control only.
    val inherited = if used { noCtx() } else { ctx }
    val r = buildBox(c, st, idOf, parentId, inherited, col)
    if r.top.count > 0 {
      used = true
    }
    top = concatIds(top, r.top)
    all = concatNodes(all, r.all)
    col = col + 1
  }
  Built(top = top, all = all)
}

func isFlat(kind: String): Bool {
  kind == "column" or kind == "row" or kind == "cardBody" or kind == "fieldBody" or kind == "dialogPanel" or
    kind == "dialogBody" or
    kind == "gridBody" or
    kind == "page" or
    kind == "spacer" or
    kind == "empty" or
    kind == "option" or
    kind == "cardTitle" or
    kind == "fieldLabel" or
    kind == "fieldError"
}

func inputActions(b: Box): List[String] {
  val a: List[String] = newList()
  if not flagOf(b, "disabled") {
    a.add("focus")
    if not flagOf(b, "readonly") {
      a.add("setValue")
    }
  }
  a
}

func intOr(s: String, d: Int): Int {
  match parseOptInt(s) {
    case Some(v) -> v
    case None -> d
  }
}

func descriptionOf(boxes: List[Box]): String {
  var s = ""
  for e in boxes {
    if e.kind == "fieldError" and e.text.length > 0 {
      if s.length > 0 {
        s = s + " "
      }
      s = s + e.text
    }
  }
  s
}

func firstHeading(b: Box): String {
  if b.kind == "heading" {
    return b.text
  }
  for c in b.children {
    val t = firstHeading(c)
    if t.length > 0 {
      return t
    }
  }
  ""
}

func buildBox(b: Box, st: AccessState, idOf: (Box) -> String, parentId: String, ctx: Ctx, index: Int): Built {
  val kind = b.kind
  if kind == "field" {
    return buildField(b, st, idOf, parentId)
  }
  if isFlat(kind) {
    val id = idFor(b, idOf, parentId)
    return buildChildren(b.children, st, idOf, id, ctx, 0)
  }
  val id = idFor(b, idOf, parentId)
  if kind == "text" {
    if b.text.length == 0 {
      return emptyBuilt()
    }
    return leaf(baseNode(id, RoleLabel, b.text, b))
  }
  if kind == "label" or kind == "badge" {
    return leaf(baseNode(id, RoleLabel, b.text, b))
  }
  if kind == "paragraph" {
    return leaf(baseNode(id, RoleParagraph, b.text, b))
  }
  if kind == "heading" {
    val lv = intOr(propOf(b.props, "level", "2"), 2)
    return leaf(baseNode(id, RoleHeading, b.text, b).copy(level = lv))
  }
  if kind == "banner" {
    val tone = propOf(b.props, "tone", "info")
    val urgent = tone == "error" or tone == "warning"
    return leaf(
      baseNode(id, if urgent { RoleAlert } else { RoleStatus }, b.text, b).copy(
        live = if urgent { "assertive" } else { "polite" }
      )
    )
  }
  if kind == "toast" {
    return leaf(baseNode(id, RoleStatus, b.text, b).copy(live = "polite"))
  }
  if kind == "spinner" {
    return leaf(baseNode(id, RoleProgress, propOf(b.props, "label", "Loading"), b))
  }
  if kind == "button" {
    val blocked = flagOf(b, "disabled") or flagOf(b, "busy")
    val a: List[String] = newList()
    if not blocked {
      a.add("focus")
      if hasEvent(b, "click") {
        a.add("click")
      }
    }
    return leaf(baseNode(id, RoleButton, b.text, b).copy(disabled = blocked, actions = a))
  }
  if kind == "link" {
    val a: List[String] = newList()
    a.add("focus")
    if hasEvent(b, "click") {
      a.add("click")
    }
    return leaf(baseNode(id, RoleLink, b.text, b).copy(description = propOf(b.props, "href", ""), actions = a))
  }
  if kind == "textInput" or kind == "numberInput" or kind == "dateInput" or kind == "textArea" {
    return leaf(inputNode(id, b, st, ctx))
  }
  if kind == "checkbox" {
    val a: List[String] = newList()
    if not flagOf(b, "disabled") {
      a.add("focus")
      if hasEvent(b, "change") {
        a.add("click")
      }
    }
    val state = if flagOf(b, "checked") { Checked } else { Unchecked }
    return leaf(
      baseNode(id, RoleCheckBox, b.text, b).copy(toggled = state, disabled = flagOf(b, "disabled"), actions = a)
    )
  }
  if kind == "select" {
    val name = if ctx.label.length > 0 { ctx.label } else { propOf(b.props, "label", "") }
    val a: List[String] = newList()
    if not flagOf(b, "disabled") {
      a.add("focus")
      a.add("click")
    }
    return leaf(
      baseNode(id, RoleComboBox, name, b).copy(
        value = b.text,
        description = ctx.description,
        invalid = ctx.invalid,
        disabled = flagOf(b, "disabled"),
        expanded = Some(value = st.openSelect == id),
        actions = a
      )
    )
  }
  if kind == "card" or kind == "section" or kind == "form" {
    val title = cardTitleOf(b)
    val role = if kind == "form" { RoleForm } else { RoleGroup }
    return parentOf(baseNode(id, role, title, b), buildChildren(b.children, st, idOf, id, noCtx(), 0))
  }
  if kind == "table" {
    return buildTable(b, st, idOf, id)
  }
  if kind == "dataGrid" {
    return buildGrid(b, st, idOf, id)
  }
  if kind == "dialog" {
    val kids = buildChildren(b.children, st, idOf, id, noCtx(), 0)
    return parentOf(baseNode(id, RoleDialog, firstHeading(b), b).copy(modal = true), kids)
  }
  if kind == "gridCell" or kind == "tableCell" {
    return buildCell(b, st, idOf, id, index)
  }
  if kind == "tableRow" or kind == "gridRow" {
    return buildRow(b, st, idOf, id, 0)
  }
  // Unknown boxes keep their text and children so nothing is hidden from the user.
  parentOf(baseNode(id, RoleGroup, b.text, b), buildChildren(b.children, st, idOf, id, noCtx(), 0))
}

func cardTitleOf(b: Box): String {
  for c in b.children {
    if c.kind == "cardTitle" {
      return c.text
    }
  }
  ""
}

func inputNode(id: String, b: Box, st: AccessState, ctx: Ctx): AccessNode {
  val kind = b.kind
  val ty = propOf(b.props, "type", "text")
  val role = if kind == "textArea" {
    RoleMultilineInput
  } else if kind == "numberInput" {
    RoleSpinButton
  } else if ty == "password" {
    RolePasswordInput
  } else {
    RoleTextInput
  }
  val fallbackName = propOf(b.props, "placeholder", "")
  val name = if ctx.label.length > 0 { ctx.label } else { fallbackName }
  // A password's value is never published.
  val shown = if ty == "password" { "" } else { propOf(b.props, "value", "") }
  var anchor = -1
  var caret = -1
  if id == st.focusId and ty != "password" {
    match st.edit(id) {
      case Some(e) -> {
        anchor = e.anchor
        caret = e.caret
      }
      case None -> ()
    }
  }
  baseNode(id, role, name, b).copy(
    value = shown,
    description = ctx.description,
    invalid = ctx.invalid,
    required = flagOf(b, "required"),
    readOnly = flagOf(b, "readonly"),
    disabled = flagOf(b, "disabled"),
    selAnchor = anchor,
    selCaret = caret,
    actions = inputActions(b)
  )
}

func buildField(b: Box, st: AccessState, idOf: (Box) -> String, parentId: String): Built {
  val id = idFor(b, idOf, parentId)
  var label = propOf(b.props, "label", "")
  val errors: List[Box] = newList()
  val controls: List[Box] = newList()
  for c in b.children {
    if c.kind == "fieldLabel" and label.length == 0 {
      label = c.text
    }
    if c.kind == "fieldBody" {
      for k in c.children {
        if k.kind == "fieldError" {
          errors.add(k)
        } else {
          controls.add(k)
        }
      }
    }
  }
  val ctx = Ctx(label = label, description = descriptionOf(errors), invalid = flagOf(b, "invalid"))
  parentOf(
    baseNode(id, RoleGroup, label, b).copy(description = ctx.description, invalid = ctx.invalid),
    buildChildren(controls, st, idOf, id, ctx, 0)
  )
}

func buildCell(b: Box, st: AccessState, idOf: (Box) -> String, id: String, index: Int): Built {
  val header = flagOf(b, "header")
  val role = if header { RoleColumnHeader } else { RoleCell }
  val n = baseNode(id, role, b.text, b).copy(colIndex = index + 1)
  if b.children.count == 0 {
    return leaf(n)
  }
  parentOf(n, buildChildren(b.children, st, idOf, id, noCtx(), 0))
}

func buildRow(b: Box, st: AccessState, idOf: (Box) -> String, id: String, rowIndex: Int): Built {
  val a: List[String] = newList()
  if hasEvent(b, "click") {
    a.add("click")
  }
  var top: List[String] = newList()
  var all: List[AccessNode] = newList()
  var k = 0
  for c in b.children {
    val cid = idFor(c, idOf, id)
    val r = buildCell(c, st, idOf, cid, k)
    top = concatIds(top, r.top)
    all = concatNodes(all, r.all)
    k = k + 1
  }
  parentOf(baseNode(id, RoleRow, "", b).copy(rowIndex = rowIndex, actions = a), Built(top = top, all = all))
}

func buildTable(b: Box, st: AccessState, idOf: (Box) -> String, id: String): Built {
  var top: List[String] = newList()
  var all: List[AccessNode] = newList()
  var cols = 0
  var ri = 0
  for r in b.children {
    if r.children.count > cols {
      cols = r.children.count
    }
    val rid = idFor(r, idOf, id)
    val built = buildRow(r, st, idOf, rid, ri + 1)
    top = concatIds(top, built.top)
    all = concatNodes(all, built.all)
    ri = ri + 1
  }
  parentOf(baseNode(id, RoleTable, "", b).copy(rowCount = ri, colCount = cols), Built(top = top, all = all))
}

func buildGrid(b: Box, st: AccessState, idOf: (Box) -> String, id: String): Built {
  val total = intOr(propOf(b.props, "rowCount", "0"), 0)
  val first = intOr(propOf(b.props, "firstRow", "0"), 0)
  var heads: List[String] = newList()
  var headAll: List[AccessNode] = newList()
  var cols = 0
  var rows: List[String] = newList()
  var rowAll: List[AccessNode] = newList()
  for c in b.children {
    if c.kind == "colheader" {
      val cid = idFor(c, idOf, id)
      val h = baseNode(cid, RoleColumnHeader, c.text, c).copy(
        colIndex = cols + 1,
        sort = propOf(c.props, "sort", ""),
        actions = colHeaderActions(c)
      )
      heads.add(h.id)
      headAll.add(h)
      cols = cols + 1
    } else if c.kind == "gridBody" {
      var ri = 0
      for r in c.children {
        val rid = idFor(r, idOf, id)
        val built = buildRow(r, st, idOf, rid, first + ri + 2)
        rows = concatIds(rows, built.top)
        rowAll = concatNodes(rowAll, built.all)
        ri = ri + 1
      }
    }
  }
  val headId = id + "#head"
  val headRow = baseNode(headId, RoleRow, "", b).copy(rowIndex = 1, childIds = heads)
  val inner: List[String] = newList()
  inner.add(headId)
  val body = concatIds(inner, rows)
  val all: List[AccessNode] = newList()
  all.add(headRow)
  for h in headAll {
    all.add(h)
  }
  for r in rowAll {
    all.add(r)
  }
  val name = propOf(b.props, "label", "")
  parentOf(baseNode(id, RoleGrid, name, b).copy(rowCount = total + 1, colCount = cols), Built(top = body, all = all))
}

func colHeaderActions(c: Box): List[String] {
  val a: List[String] = newList()
  if propOf(c.props, "sort", "").length > 0 {
    a.add("focus")
    a.add("click")
  }
  a
}

func findNode(nodes: List[AccessNode], id: String): Option[AccessNode] {
  for n in nodes {
    if n.id == id {
      return Some(value = n)
    }
  }
  None
}

/// The accessibility tree of `page` (the box `Ui.Native.Layout.layoutTree` returns).  `title`
/// names the window; `idOf` is the host's stable id of a box ("" for boxes it does not identify).
pub func buildTree(page: in Box, title: in String, st: in AccessState, idOf: in (Box) -> String): AccessTree {
  val rid = rootId()
  val kids = buildChildren(page.children, st, idOf, rid, noCtx(), 0)
  val root = baseNode(rid, RoleWindow, title, page).copy(childIds = kids.top)
  val nodes: List[AccessNode] = newList()
  nodes.add(root)
  for k in kids.all {
    nodes.add(k)
  }
  val focus = match findNode(nodes, st.focusId) { case Some(_) -> st.focusId; case None -> rid }
  AccessTree(rootId = rid, focus = focus, nodes = nodes)
}

// ─── Diffing ──────────────────────────────────────────────────────────────────
func joined(xs: List[String]): String {
  var s = ""
  for x in xs {
    s = s + x.length.toString() + ":" + x + ";"
  }
  s
}

func expandedName(e: Option[Bool]): String {
  match e {
    case Some(v) -> if v { "t" } else { "f" }
    case None -> "-"
  }
}

/// A string that is equal for two nodes exactly when every published property is equal.
pub func signature(n: in AccessNode): String {
  val parts: List[String] = newList()
  parts.add(n.id)
  parts.add(roleName(n.role))
  parts.add(n.name)
  parts.add(n.description)
  parts.add(n.value)
  parts.add(n.level.toString())
  parts.add(toggledName(n.toggled))
  parts.add(expandedName(n.expanded))
  parts.add(n.live)
  parts.add(if n.modal { "m" } else { "-" })
  parts.add(if n.disabled { "d" } else { "-" })
  parts.add(if n.invalid { "i" } else { "-" })
  parts.add(if n.required { "r" } else { "-" })
  parts.add(if n.readOnly { "o" } else { "-" })
  parts.add(n.sort)
  parts.add(n.rowCount.toString())
  parts.add(n.colCount.toString())
  parts.add(n.rowIndex.toString())
  parts.add(n.colIndex.toString())
  parts.add(n.selAnchor.toString())
  parts.add(n.selCaret.toString())
  parts.add(n.x.toString())
  parts.add(n.y.toString())
  parts.add(n.w.toString())
  parts.add(n.h.toString())
  parts.add(joined(n.actions))
  parts.add(joined(n.childIds))
  joined(parts)
}

/// What to send a platform adapter after the tree changed: the nodes that are new or differ, the
/// ids that are gone, and the focus.  `full` is set when there was no previous tree, so the
/// adapter must treat `changed` as the whole tree.
pub record AccessUpdate {
  full: Bool
  changed: List[AccessNode]
  removed: List[String]
  focus: String
  focusChanged: Bool
}

pub func diffTrees(prev: in Option[AccessTree], next: in AccessTree): AccessUpdate {
  match prev {
    case None -> AccessUpdate(
      full = true,
      changed = next.nodes,
      removed = newList(),
      focus = next.focus,
      focusChanged = true
    )
    case Some(p) -> {
      val before: Map[String, String] = newMap()
      for n in p.nodes {
        before.add(n.id, signature(n))
      }
      val seen: Map[String, Bool] = newMap()
      val changed: List[AccessNode] = newList()
      for n in next.nodes {
        seen.add(n.id, true)
        match mapGet(before, n.id) {
          case Some(sig) -> {
            if sig != signature(n) {
              changed.add(n)
            }
          }
          case None -> changed.add(n)
        }
      }
      val removed: List[String] = newList()
      for n in p.nodes {
        match mapGet(seen, n.id) {
          case Some(_) -> ()
          case None -> removed.add(n.id)
        }
      }
      AccessUpdate(
        full = false,
        changed = changed,
        removed = removed,
        focus = next.focus,
        focusChanged = p.focus != next.focus or p.rootId != next.rootId
      )
    }
  }
}

// ─── Requests from assistive technology ───────────────────────────────────────
/// What an assistive technology asks of a node.
pub enum RequestKind {
  case ReqFocus
  case ReqClick
  case ReqSetValue
  case ReqScrollIntoView
}

pub record AccessRequest {
  kind: RequestKind
  /// The new text of a `ReqSetValue`.
  text: String
}

/// How the host carries out a request.
pub union Resolution {
  /// The node does not exist, is disabled, is outside the open dialog, or lacks the action.
  case Unresolved
  /// Move keyboard focus to the box with this id.
  case FocusBox(id: String)
  /// Send these protocol events, as a click on the box would.
  case Send(actions: List[Action])
  /// The click is handled by the host itself (opening a select, sorting a column, caret
  /// placement): do what a pointer click at the centre of the box with this id does.
  case HostClick(id: String)
  /// Replace the text of the input with this id and path and send its `input` event.
  case SetText(id: String, path: List[Int], text: String)
  /// Scroll the page so the box with this id is visible.
  case ScrollTo(id: String, y: Float)
}

func findBox(b: Box, id: String, idOf: (Box) -> String): Option[Box] {
  val own = idFor(b, idOf, "")
  if b.kind != "page" and (own == id or own + "/inner" == id) {
    return Some(value = b)
  }
  for c in b.children {
    match findBox(c, id, idOf) {
      case Some(f) -> return Some(value = f)
      case None -> ()
    }
  }
  None
}

func findDialogBox(b: Box): Option[Box] {
  if b.kind == "dialog" {
    return Some(value = b)
  }
  for c in b.children {
    match findDialogBox(c) {
      case Some(d) -> return Some(value = d)
      case None -> ()
    }
  }
  None
}

func hasAction(n: AccessNode, name: String): Bool {
  for a in n.actions {
    if a == name {
      return true
    }
  }
  false
}

func insideDialog(page: Box, id: String, idOf: (Box) -> String): Bool {
  match findDialogBox(page) {
    case None -> true
    case Some(d) -> {
      if idFor(d, idOf, "") == id {
        return true
      }
      match findBox(d, id, idOf) {
        case Some(_) -> true
        case None -> false
      }
    }
  }
}

/// The request `req` for node `id` of `tree`, resolved against the laid-out `page`.  A dialog
/// is modal: nothing outside it can be reached.
pub func resolveRequest(
  page: in Box,
  tree: in AccessTree,
  idOf: in (Box) -> String,
  id: in String,
  req: in AccessRequest,
): Resolution {
  match findNode(tree.nodes, id) {
    case None -> Unresolved
    case Some(node) -> resolveNode(page, tree, idOf, node, req)
  }
}

func resolveNode(page: Box, tree: AccessTree, idOf: (Box) -> String, node: AccessNode, req: AccessRequest): Resolution {
  val id = node.id
  if node.disabled or id == tree.rootId {
    return Unresolved
  }
  if not insideDialog(page, id, idOf) {
    return Unresolved
  }
  match req.kind {
    case ReqFocus -> if hasAction(node, "focus") { FocusBox(id = id) } else { Unresolved }
    case ReqScrollIntoView -> ScrollTo(id = id, y = node.y)
    case ReqSetValue -> {
      if not hasAction(node, "setValue") {
        return Unresolved
      }
      match findBox(page, id, idOf) {
        case Some(b) -> SetText(id = id, path = b.path, text = req.text)
        case None -> Unresolved
      }
    }
    case ReqClick -> {
      if not hasAction(node, "click") {
        return Unresolved
      }
      match findBox(page, id, idOf) {
        case None -> Unresolved
        case Some(b) -> {
          val acts = clickActions(b)
          if acts.count > 0 {
            Send(actions = acts)
          } else {
            HostClick(id = id)
          }
        }
      }
    }
  }
}
