//! Ui.Html — a rendered view as HTML, for the first paint before the
//! session socket connects (docs/65-ui-library-sketch.md §13.4, D152).
//!
//! The markup matches what the TypeScript runtime's `DomRenderer` builds for
//! the same node (runtime/src/render.ts): the same elements, classes,
//! roles and ARIA attributes, so replacing it with the live tree once the
//! socket connects changes nothing on screen.  It carries no event
//! handlers; the page is inert until the runtime takes over.
@runtime_checked
@pure
package Ui.Html

import Std.Core
import Std.Collections
import Std.String
import Std.Parse.{parseOptInt}
import Ui.Core.{Prop}
import Ui.Diff.{WireNode, WElement, WText, WEmpty}
import Std.JsonValue.{JsonValue, JArray, parseValue, getString}

/// `n` as HTML.  Element ids (`lui-s1`, `lui-s2`, ...) are numbered in
/// document order, so the same tree always renders the same text.
pub func renderHtml(n: in WireNode): String {
  val start: List[Int] = newList()
  start.add(1)
  return node(n, IdCounter(next = start), "", "")
}

/// `s` safe for HTML text and double-quoted attribute values.
pub func escapeHtml(s: in String): String {
  var acc = replace(s, "&", "&amp;")
  acc = replace(acc, "<", "&lt;")
  acc = replace(acc, ">", "&gt;")
  acc = replace(acc, "\"", "&quot;")
  return replace(acc, "'", "&#39;")
}

// The next element id, held in a one-slot list so it is shared down the
// recursion.
record IdCounter {
  next: List[Int]
}

func freshId(ids: in IdCounter): String {
  val n = ids.next[0]
  ids.next[0] = n + 1
  return "lui-s" + n.toString()
}

func prop(props: in List[Prop], name: in String): Option[String] {
  for p in props {
    if p.name == name {
      return Some(value = p.value)
    }
  }
  return None
}

func flag(props: in List[Prop], name: in String): Bool {
  return match prop(props, name) { case Some(v) -> v == "true"; case None -> false }
}

func text(props: in List[Prop], name: in String): String {
  return match prop(props, name) { case Some(v) -> v; case None -> "" }
}

func attr(name: in String, value: in String): String {
  return " " + name + "=\"" + escapeHtml(value) + "\""
}

func optAttr(props: in List[Prop], propName: in String, attrName: in String): String {
  return match prop(props, propName) { case Some(v) -> attr(attrName, v); case None -> "" }
}

func boolAttr(on: in Bool, name: in String): String {
  return if on then " " + name else ""
}

// The attributes every element takes from its props: `variant` and `tone`
// as data attributes.
func dataAttrs(props: in List[Prop]): String {
  return optAttr(props, "variant", "data-variant") + optAttr(props, "tone", "data-tone")
}

func classes(base: in String, props: in List[Prop]): String {
  return attr("class", if flag(props, "invalid") then base + " lui-invalid" else base)
}

// `forcedId` is an id chosen by the enclosing field (its error messages);
// `controlAttrs` are ARIA attributes the enclosing field puts on its input.
func node(n: in WireNode, ids: in IdCounter, forcedId: in String, controlAttrs: in String): String {
  return match n {
    case WText(v) -> escapeHtml(v)
    case WEmpty -> "<!--empty-->"
    case WElement(kind, _, props, _, children) -> element(kind, props, children, ids, forcedId, controlAttrs)
  }
}

func childrenHtml(children: in List[WireNode], ids: in IdCounter): String {
  var acc = ""
  for c in children {
    acc = acc + node(c, ids, "", "")
  }
  return acc
}

func wrap(
  tag: in String,
  cls: in String,
  props: in List[Prop],
  extra: in String,
  children: in List[WireNode],
  ids: in IdCounter,
): String {
  return "<" + tag + classes(cls, props) + dataAttrs(props) + extra + ">" + childrenHtml(children, ids) + "</" + tag +
    ">"
}

func element(
  kind: in String,
  props: in List[Prop],
  children: in List[WireNode],
  ids: in IdCounter,
  forcedId: in String,
  controlAttrs: in String,
): String {
  if kind == "column" {
    return wrap("div", "lui-column", props, "", children, ids)
  }
  if kind == "row" {
    return wrap("div", "lui-row", props, "", children, ids)
  }
  if kind == "card" or kind == "section" {
    val titleTag = if kind == "card" then "h2" else "h3"
    return "<section" + classes("lui-" + kind, props) + dataAttrs(props) + "><" + titleTag +
      attr("class", "lui-" + kind + "-title") +
      ">" +
      escapeHtml(text(props, "title")) +
      "</" +
      titleTag +
      "><div" +
      attr("class", "lui-" + kind + "-body") +
      ">" +
      childrenHtml(children, ids) +
      "</div></section>"
  }
  if kind == "spacer" {
    return "<div" + classes("lui-spacer", props) + dataAttrs(props) + "></div>"
  }
  if kind == "heading" {
    val raw = match prop(props, "level") { case Some(v) -> v; case None -> "1" }
    val level = if raw == "2" then "2" else if raw == "3" then "3" else "1"
    return wrap("h" + level, "lui-heading", props, "", children, ids)
  }
  if kind == "paragraph" {
    return wrap("p", "lui-paragraph", props, "", children, ids)
  }
  if kind == "label" {
    return wrap("span", "lui-label", props, "", children, ids)
  }
  if kind == "badge" {
    return wrap("span", "lui-badge", props, "", children, ids)
  }
  if kind == "banner" {
    val tone = text(props, "tone")
    val role = if tone == "error" or tone == "warning" then "alert" else "status"
    return wrap("div", "lui-banner", props, attr("role", role), children, ids)
  }
  if kind == "spinner" {
    return "<div" + classes("lui-spinner", props) + dataAttrs(props) + attr("role", "status") +
      optAttr(props, "label", "aria-label") +
      "></div>"
  }
  if kind == "fieldError" {
    val id = if forcedId.length > 0 then forcedId else freshId(ids)
    return wrap("div", "lui-field-error", props, attr("id", id), children, ids)
  }
  if kind == "field" {
    return field(props, children, ids)
  }
  if kind == "textInput" or kind == "numberInput" or kind == "dateInput" {
    val id = if forcedId.length > 0 then forcedId else freshId(ids)
    val inputType = inputTypeOf(kind, props)
    val numeric = if kind == "numberInput" then attr("inputmode", "numeric") else ""
    return "<input" + classes("lui-input", props) + dataAttrs(props) + attr("id", id) + attr("type", inputType) + numeric +
      attr("value", text(props, "value")) +
      inputAttrs(props) +
      controlAttrs +
      ">"
  }
  if kind == "textArea" {
    val id = if forcedId.length > 0 then forcedId else freshId(ids)
    return "<textarea" + classes("lui-input lui-textarea", props) + dataAttrs(props) + attr("id", id) + inputAttrs(props) +
      controlAttrs +
      ">" +
      escapeHtml(text(props, "value")) +
      "</textarea>"
  }
  if kind == "checkbox" {
    val id = if forcedId.length > 0 then forcedId else freshId(ids)
    return "<label" + classes("lui-checkbox", props) + dataAttrs(props) + "><input" + attr("class", "") +
      attr("type", "checkbox") +
      attr("id", id) +
      boolAttr(flag(props, "checked"), "checked") +
      stateAttrs(props) +
      controlAttrs +
      "><span" +
      attr("class", "") +
      ">" +
      escapeHtml(text(props, "label")) +
      "</span></label>"
  }
  if kind == "select" {
    val id = if forcedId.length > 0 then forcedId else freshId(ids)
    val selected = text(props, "value")
    var opts = ""
    for c in children {
      opts = opts + option(c, selected, ids)
    }
    return "<select" + classes("lui-select", props) + dataAttrs(props) + attr("id", id) + stateAttrs(props) + controlAttrs +
      ">" +
      opts +
      "</select>"
  }
  if kind == "option" {
    return "<option" + attr("class", "") + attr("value", text(props, "value")) + ">" + childrenHtml(children, ids) +
      "</option>"
  }
  if kind == "button" {
    val busy = flag(props, "busy")
    val busyAttr = match prop(props, "busy") {
      case Some(_) -> attr("aria-busy", if busy then "true" else "false")
      case None -> ""
    }
    return "<button" + classes("lui-button", props) + dataAttrs(props) + attr("type", "button") + busyAttr +
      boolAttr(busy or flag(props, "disabled"), "disabled") +
      ">" +
      escapeHtml(text(props, "label")) +
      "</button>"
  }
  if kind == "link" {
    return wrap("a", "lui-link", props, optAttr(props, "href", "href"), children, ids)
  }
  if kind == "table" {
    return wrap("table", "lui-table", props, "", children, ids)
  }
  if kind == "tableRow" {
    return wrap("tr", "lui-table-row", props, "", children, ids)
  }
  if kind == "tableCell" {
    return wrap(if flag(props, "header") then "th" else "td", "lui-table-cell", props, "", children, ids)
  }
  if kind == "dataGrid" {
    return dataGrid(props, children, ids)
  }
  if kind == "gridRow" {
    return gridRow(props, children, ids, 0)
  }
  if kind == "gridCell" {
    return wrap("div", "lui-grid-cell", props, attr("role", "gridcell"), children, ids)
  }
  if kind == "form" {
    return wrap("form", "lui-form", props, " novalidate", children, ids)
  }
  if kind == "dialog" {
    return "<div" + classes("lui-dialog-backdrop", props) + dataAttrs(props) + "><div" + attr("class", "lui-dialog") +
      attr("role", "dialog") +
      attr("aria-modal", "true") +
      ">" +
      childrenHtml(children, ids) +
      "</div></div>"
  }
  return "<div" + attr("class", "lui-unknown") + ">Unsupported widget: " + escapeHtml(kind) + "</div>"
}

// The `type` of an input: a date picker for dates; a text input may carry
// its own (`email`, `password`); a number input is text with a numeric
// keyboard, since a draft may hold text that is not yet a number.
func inputTypeOf(kind: in String, props: in List[Prop]): String {
  if kind == "dateInput" {
    return "date"
  }
  if kind == "textInput" {
    return match prop(props, "type") { case Some(t) -> t; case None -> "text" }
  }
  return "text"
}

// An option of a select, marked selected when its value is the select's.
func option(c: in WireNode, selected: in String, ids: in IdCounter): String {
  return match c {
    case WElement(kind, _, props, _, children) -> if kind == "option" {
      val v = text(props, "value")
      "<option" + attr("class", "") + attr("value", v) + boolAttr(v == selected, "selected") + ">" +
        childrenHtml(children, ids) +
        "</option>"
    } else {
      node(c, ids, "", "")
    }
    case _ -> node(c, ids, "", "")
  }
}

// `disabled`, `readonly` and `required` (with `aria-required`).
func stateAttrs(props: in List[Prop]): String {
  val required = match prop(props, "required") {
    case Some(v) -> attr("aria-required", if v == "true" then "true" else "false")
    case None -> ""
  }
  return boolAttr(flag(props, "disabled"), "disabled") + boolAttr(flag(props, "readonly"), "readonly") +
    boolAttr(flag(props, "required"), "required") +
    required
}

// What a text input or text area takes from its props.
func inputAttrs(props: in List[Prop]): String {
  return optAttr(props, "placeholder", "placeholder") + optAttr(props, "min", "min") + optAttr(props, "max", "max") +
    optAttr(props, "maxLength", "maxlength") +
    stateAttrs(props)
}

func isFieldError(n: in WireNode): Bool {
  return match n { case WElement(kind, _, _, _, _) -> kind == "fieldError"; case _ -> false }
}

// A labelled field: its first child is the control, and its field errors
// describe it, as the runtime's `afterChildrenChanged` arranges.
func field(props: in List[Prop], children: in List[WireNode], ids: in IdCounter): String {
  val label = text(props, "label")
  if children.count == 0 {
    return "<div" + classes("lui-field", props) + dataAttrs(props) + "><label" + attr("class", "lui-field-label") + ">" +
      escapeHtml(label) +
      "</label><div" +
      attr("class", "lui-field-body") +
      "></div></div>"
  }
  val controlId = freshId(ids)
  val errorIds: List[String] = newList()
  var i = 1
  while i < children.count {
    if isFieldError(children[i]) {
      errorIds.add(freshId(ids))
    }
    i += 1
  }
  val describedBy = if errorIds.count > 0 then attr("aria-describedby", joinList(" ", errorIds)) + attr("aria-invalid", "true") else ""
  var body = node(children[0], ids, controlId, describedBy)
  var e = 0
  var j = 1
  while j < children.count {
    if isFieldError(children[j]) {
      body = body + node(children[j], ids, errorIds[e], "")
      e += 1
    } else {
      body = body + node(children[j], ids, "", "")
    }
    j += 1
  }
  return "<div" + classes("lui-field", props) + dataAttrs(props) + "><label" + attr("class", "lui-field-label") +
    attr("for", controlId) +
    ">" +
    escapeHtml(label) +
    "</label><div" +
    attr("class", "lui-field-body") +
    ">" +
    body +
    "</div></div>"
}

// A column of a data grid, as its `columns` property describes it.
record HeaderCell {
  id: String
  title: String
  sort: String
}

// The grid's columns; an unreadable property gives none.
func gridColumns(props: in List[Prop]): List[HeaderCell] {
  val acc: List[HeaderCell] = newList()
  val items = match parseValue(text(props, "columns")) {
    case Ok(v) -> match v { case JArray(xs) -> xs; case _ -> return acc }
    case Err(_) -> return acc
  }
  for item in items {
    val id = match getString(item, "id") { case Some(v) -> v; case None -> "" }
    val title = match getString(item, "title") { case Some(v) -> v; case None -> "" }
    val sort = match getString(item, "sort") { case Some(v) -> v; case None -> "" }
    acc.add(HeaderCell(id = id, title = title, sort = sort))
  }
  return acc
}

// A non-negative integer property, or `fallback`.
func intProp(props: in List[Prop], name: in String, fallback: in Int): Int {
  return match prop(props, name) {
    case Some(v) -> match parseOptInt(v) {
      case Some(n) -> if n >= 0 then n else fallback
      case None -> fallback
    }
    case None -> fallback
  }
}

// A data grid, laid out as the runtime's renderer lays it out: a header row,
// then a scrolling body whose padding stands in for the rows not rendered,
// so the scrollbar spans all `rowCount` rows.
func dataGrid(props: in List[Prop], children: in List[WireNode], ids: in IdCounter): String {
  val cols = gridColumns(props)
  val total = intProp(props, "rowCount", 0)
  val first = intProp(props, "firstRow", 0)
  val rowHeight = intProp(props, "rowHeight", 36)
  val visible = intProp(props, "visibleRows", 10)
  val rest = total - first - children.count
  val after = if rest > 0 then rest else 0
  var header = ""
  for c in cols {
    if c.sort.length > 0 {
      header = header + "<div" + attr("class", "lui-grid-colheader") + attr("role", "columnheader") +
        attr("aria-sort", c.sort) +
        "><button" +
        attr("class", "lui-grid-sort") +
        attr("type", "button") +
        ">" +
        escapeHtml(c.title) +
        "</button></div>"
    } else {
      header = header + "<div" + attr("class", "lui-grid-colheader") + attr("role", "columnheader") + ">" +
        escapeHtml(c.title) +
        "</div>"
    }
  }
  var rows = ""
  var i = 0
  while i < children.count {
    rows = rows + gridRowNode(children[i], ids, first + i + 2)
    i += 1
  }
  return "<div" + classes("lui-grid", props) + dataAttrs(props) + attr("role", "grid") +
    optAttr(props, "label", "aria-label") +
    attr("aria-rowcount", (total + 1).toString()) +
    attr("aria-colcount", cols.count.toString()) +
    attr(
      "style",
      "--lui-grid-cols:" + cols.count.toString() + ";--lui-grid-row-height:" + rowHeight.toString() + "px"
    ) +
    "><div" +
    attr("class", "lui-grid-header") +
    attr("role", "rowgroup") +
    "><div" +
    attr("class", "lui-grid-row") +
    attr("role", "row") +
    attr("aria-rowindex", "1") +
    ">" +
    header +
    "</div></div><div" +
    attr("class", "lui-grid-body") +
    attr("tabindex", "0") +
    attr("style", "height:" + (visible * rowHeight).toString() + "px") +
    "><div" +
    attr("class", "lui-grid-rows") +
    attr("role", "rowgroup") +
    attr(
      "style",
      "padding-top:" + (first * rowHeight).toString() + "px;padding-bottom:" + (after * rowHeight).toString() +
        "px"
    ) +
    ">" +
    rows +
    "</div></div></div>"
}

// A child of a data grid: a row numbered `rowIndex` (1 is the header), or
// any other node as it renders anywhere.
func gridRowNode(n: in WireNode, ids: in IdCounter, rowIndex: in Int): String {
  return match n {
    case WElement(kind, _, props, _, children) -> if kind == "gridRow" then gridRow(props, children, ids, rowIndex) else node(n, ids, "", "")
    case _ -> node(n, ids, "", "")
  }
}

// A data grid row; `rowIndex` 0 when it is not inside a grid.
func gridRow(props: in List[Prop], children: in List[WireNode], ids: in IdCounter, rowIndex: in Int): String {
  val index = if rowIndex > 0 then attr("aria-rowindex", rowIndex.toString()) else ""
  return wrap("div", "lui-grid-row", props, attr("role", "row") + attr("tabindex", "-1") + index, children, ids)
}
