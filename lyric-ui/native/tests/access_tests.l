@test_module
package Ui.Native.AccessTests

import Std.Core
import Std.Collections
import Std.Testing
import Ui.Core.{View, Prop}
import Ui.Diff.{WireNode, toWire}
import Ui.Protocol.{refsKey}
import Ui.Widgets
import Ui.Widgets.{GridColumn}
import Ui.Native.Client.{eventPath}
import Ui.Native.Interact.{TextEdit}
import Ui.Native.Layout.{Box, layoutTree, testEnv}
import Ui.Native.Access

union Msg {
  case Hit
  case Typed(s: String)
  case Sorted(c: String)
  case Scrolled(r: Ui.Core.RowRange)
}

func lay(v: View[Msg]): Box {
  layoutTree(toWire(v), testEnv(800.0f32, 600.0f32), 0.0f32)
}

func noId(b: Box): String {
  ""
}

func idle(): Access.AccessState {
  Access.AccessState(focusId = "", openSelect = "", edit = { id: String -> None })
}

func build(v: View[Msg]): Access.AccessTree {
  Access.buildTree(lay(v), "Customers", idle(), { b: Box -> noId(b) })
}

func roles(t: Access.AccessTree): List[String] {
  val r: List[String] = newList()
  for n in t.nodes {
    r.add(Access.roleName(n.role))
  }
  r
}

func nodeWith(t: Access.AccessTree, role: String): Access.AccessNode {
  for n in t.nodes {
    if Access.roleName(n.role) == role {
      return n
    }
  }
  t.nodes[0]
}

func countRole(t: Access.AccessTree, role: String): Int {
  var c = 0
  for n in t.nodes {
    if Access.roleName(n.role) == role {
      c = c + 1
    }
  }
  c
}

func form(errors: List[String], checked: Bool): View[Msg] {
  val kids: List[View[Msg]] = newList()
  kids.add(Widgets.heading(1, "Customer"))
  kids.add(
    Widgets.field("Name", errors, Widgets.textInput("text", "Ada", { s: String -> Typed(s = s) }, Widgets.inputOpts()))
  )
  kids.add(Widgets.checkbox("Subscribe", checked, { s: String -> Typed(s = s) }))
  val actions: List[View[Msg]] = newList()
  actions.add(Widgets.button("Cancel", Hit))
  actions.add(Widgets.primaryButton("Save", Hit, false))
  kids.add(Widgets.row(actions))
  Widgets.form(Hit, kids)
}

test "the root is the window, layout helpers are flattened away" {
  val t = build(form(newList(), false))
  assertEqual(t.rootId, "root", "root id")
  assertEqual(Access.roleName(t.nodes[0].role), "window", "root role")
  assertEqual(t.nodes[0].name, "Customers", "window title")
  assertEqual(roles(t)[1], "form", "the form")
  assertEqualInt(countRole(t, "group"), 1, "only the field is a group: no column or row nodes")
  assertEqualInt(countRole(t, "button"), 2, "two buttons")
}

test "a heading carries its level" {
  val t = build(form(newList(), false))
  val h = nodeWith(t, "heading")
  assertEqual(h.name, "Customer", "name")
  assertEqualInt(h.level, 1, "level")
}

test "a field's label names its control and its errors describe it" {
  val errs: List[String] = newList()
  errs.add("Required")
  errs.add("Too short")
  val t = build(form(errs, false))
  val input = nodeWith(t, "textbox")
  assertEqual(input.name, "Name", "label becomes the name")
  assertEqual(input.value, "Ada", "value")
  assertEqual(input.description, "Required Too short", "errors become the description")
  assertTrue(input.invalid, "invalid")
  val clean = nodeWith(build(form(newList(), false)), "textbox")
  assertTrue(not clean.invalid, "valid without errors")
  assertEqual(clean.description, "", "no description")
}

test "a checkbox reports its checked state" {
  val off = nodeWith(build(form(newList(), false)), "checkbox")
  assertEqual(off.name, "Subscribe", "name")
  assertEqual(Access.toggledName(off.toggled), "false", "unchecked")
  val on = nodeWith(build(form(newList(), true)), "checkbox")
  assertEqual(Access.toggledName(on.toggled), "true", "checked")
  assertTrue(Access.signature(off) != Access.signature(on), "a toggle changes the signature")
}

test "buttons are named by their label, a busy button is disabled" {
  val kids: List[View[Msg]] = newList()
  kids.add(Widgets.button("Cancel", Hit))
  kids.add(Widgets.primaryButton("Save", Hit, true))
  val t = build(Widgets.column(kids))
  var cancel = 0
  var save = 0
  for n in t.nodes {
    if n.name == "Cancel" {
      cancel = if n.disabled { 2 } else { 1 }
    }
    if n.name == "Save" {
      save = if n.disabled { 2 } else { 1 }
    }
  }
  assertEqualInt(cancel, 1, "cancel enabled")
  assertEqualInt(save, 2, "save busy is disabled")
}

test "a password never publishes its value and a number input is a spin button" {
  val kids: List[View[Msg]] = newList()
  kids.add(Widgets.textInput("password", "hunter2", { s: String -> Typed(s = s) }, Widgets.inputOpts()))
  kids.add(Widgets.numberInput("42", { s: String -> Typed(s = s) }, Widgets.inputOpts(), None))
  kids.add(Widgets.textArea("a\nb", { s: String -> Typed(s = s) }, Widgets.inputOpts()))
  val t = build(Widgets.column(kids))
  assertEqual(nodeWith(t, "password").value, "", "password value withheld")
  assertEqual(nodeWith(t, "spinbutton").value, "42", "number")
  assertEqual(nodeWith(t, "textbox-multiline").value, "a\nb", "text area")
}

test "the focused input publishes its selection" {
  val page = lay(form(newList(), false))
  val idOf = { b: Box -> noId(b) }
  val plain = Access.buildTree(page, "W", idle(), idOf)
  val inputId = nodeWith(plain, "textbox").id
  val st = Access.AccessState(
    focusId = inputId,
    openSelect = "",
    edit = { id: String -> Some(value = TextEdit(caret = 3, anchor = 1, scrollX = 0.0f32)) }
  )
  val t = Access.buildTree(page, "W", st, idOf)
  val input = nodeWith(t, "textbox")
  assertEqual(t.focus, inputId, "focus follows the focused id")
  assertEqualInt(input.selCaret, 3, "caret")
  assertEqualInt(input.selAnchor, 1, "anchor")
  assertEqualInt(nodeWith(plain, "textbox").selCaret, -1, "no selection when not focused")
  assertEqual(plain.focus, "root", "focus defaults to the root")
}

test "banners are live regions and urgent ones are alerts" {
  val kids: List[View[Msg]] = newList()
  kids.add(Widgets.banner("info", "Saved"))
  kids.add(Widgets.banner("error", "Failed"))
  kids.add(Widgets.spinner("Loading customers"))
  val t = build(Widgets.column(kids))
  val status = nodeWith(t, "status")
  assertEqual(status.live, "polite", "info is polite")
  val alert = nodeWith(t, "alert")
  assertEqual(alert.live, "assertive", "error is assertive")
  assertEqual(alert.name, "Failed", "text")
  assertEqual(nodeWith(t, "progressbar").name, "Loading customers", "spinner label")
}

test "a table has row and column counts and header cells" {
  val rows: List[View[Msg]] = newList()
  val cells: List[View[Msg]] = newList()
  cells.add(Widgets.text("Ada"))
  cells.add(Widgets.text("ada@example.com"))
  rows.add(Widgets.keyed("r1", Widgets.tableRow(cells, Some(value = Hit))))
  val hs: List[String] = newList()
  hs.add("Name")
  hs.add("Email")
  val t = build(Widgets.table(hs, rows))
  val table = nodeWith(t, "table")
  assertEqualInt(table.rowCount, 2, "header and one row")
  assertEqualInt(table.colCount, 2, "columns")
  assertEqualInt(countRole(t, "columnheader"), 2, "header cells")
  assertEqualInt(countRole(t, "cell"), 2, "data cells")
  assertEqualInt(countRole(t, "row"), 2, "rows")
  var clickable = 0
  for n in t.nodes {
    if Access.roleName(n.role) == "row" and n.rowIndex == 2 and n.actions.count == 1 {
      clickable = clickable + 1
    }
  }
  assertEqualInt(clickable, 1, "the activatable row can be clicked")
}

func gridView(first: Int, total: Int, rows: Int): View[Msg] {
  val cols: List[GridColumn] = newList()
  cols.add(GridColumn(id = "name", title = "Name", sortable = true))
  cols.add(GridColumn(id = "email", title = "Email", sortable = false))
  val rs: List[View[Msg]] = newList()
  var i = 0
  while i < rows {
    val cells: List[View[Msg]] = newList()
    cells.add(Widgets.text("n" + (first + i).toString()))
    cells.add(Widgets.text("e" + (first + i).toString()))
    rs.add(Widgets.keyed("k" + (first + i).toString(), Widgets.gridRow(cells, Some(value = Hit))))
    i = i + 1
  }
  Widgets.dataGrid(
    Widgets.gridSpec("People", cols, total, first),
    rs,
    { r: Ui.Core.RowRange -> Scrolled(r = r) },
    { c: String -> Sorted(c = c) }
  )
}

test "a data grid counts every row including unloaded ones and indexes the loaded ones" {
  val t = build(gridView(5, 100, 3))
  val g = nodeWith(t, "grid")
  assertEqual(g.name, "People", "label")
  assertEqualInt(g.rowCount, 101, "total rows plus the header row")
  assertEqualInt(g.colCount, 2, "columns")
  val idx: List[Int] = newList()
  for n in t.nodes {
    if Access.roleName(n.role) == "row" {
      idx.add(n.rowIndex)
    }
  }
  assertEqualInt(idx.count, 4, "header row and three loaded rows")
  assertEqualInt(idx[0], 1, "header row is row 1")
  assertEqualInt(idx[1], 7, "row 5 is the seventh row")
  assertEqualInt(idx[3], 9, "and the loaded rows are consecutive")
}

test "a sortable column header carries its direction and a click action" {
  val t = build(gridView(0, 10, 2))
  var found = 0
  for n in t.nodes {
    if Access.roleName(n.role) == "columnheader" and n.name == "Name" {
      found = found + 1
      assertEqual(n.sort, "none", "sortable but unsorted")
      assertEqualInt(n.colIndex, 1, "column index")
      assertEqualInt(n.actions.count, 2, "focus and click")
    }
    if Access.roleName(n.role) == "columnheader" and n.name == "Email" {
      assertEqual(n.sort, "", "not sortable")
      assertEqualInt(n.actions.count, 0, "no actions")
    }
  }
  assertEqualInt(found, 1, "the name header")
}

func dialogView(): View[Msg] {
  val kids: List[View[Msg]] = newList()
  kids.add(Widgets.button("Behind", Hit))
  val dk: List[View[Msg]] = newList()
  dk.add(Widgets.heading(2, "Delete customer?"))
  dk.add(Widgets.button("Confirm", Hit))
  kids.add(Ui.Widgets.element(Ui.Core.WidgetKind.Dialog, Widgets.noProps(), newList(), dk))
  Widgets.column(kids)
}

func idOfNamed(t: Access.AccessTree, name: String): String {
  for n in t.nodes {
    if n.name == name {
      return n.id
    }
  }
  ""
}

test "a dialog is modal, named by its heading, and blocks requests outside it" {
  val page = lay(dialogView())
  val idOf = { b: Box -> noId(b) }
  val t = Access.buildTree(page, "W", idle(), idOf)
  val d = nodeWith(t, "dialog")
  assertTrue(d.modal, "modal")
  assertEqual(d.name, "Delete customer?", "named by its heading")
  val click = Access.AccessRequest(kind = Access.ReqClick, text = "")
  match Access.resolveRequest(page, t, idOf, idOfNamed(t, "Behind"), click) {
    case Access.Unresolved -> ()
    case _ -> assertTrue(false, "a node behind a dialog cannot be activated")
  }
  match Access.resolveRequest(page, t, idOf, idOfNamed(t, "Confirm"), click) {
    case Access.Send(actions) -> assertEqual(actions[0].name, "click", "click event")
    case _ -> assertTrue(false, "the dialog's button resolves to a click event")
  }
}

test "requests become the actions the mouse and keyboard produce" {
  val page = lay(form(newList(), false))
  val idOf = { b: Box -> noId(b) }
  val t = Access.buildTree(page, "W", idle(), idOf)
  val input = nodeWith(t, "textbox")
  val box = nodeWith(t, "checkbox")
  match Access.resolveRequest(page, t, idOf, input.id, Access.AccessRequest(kind = Access.ReqFocus, text = "")) {
    case Access.FocusBox(id) -> assertEqual(id, input.id, "focus the input")
    case _ -> assertTrue(false, "focus")
  }
  match Access.resolveRequest(page, t, idOf, input.id, Access.AccessRequest(kind = Access.ReqSetValue, text = "Grace")) {
    case Access.SetText(id, path, text) -> assertEqual(text, "Grace", "the new text")
    case _ -> assertTrue(false, "set value")
  }
  match Access.resolveRequest(page, t, idOf, box.id, Access.AccessRequest(kind = Access.ReqClick, text = "")) {
    case Access.Send(actions) -> assertEqual(actions[0].data, "true", "checking an unchecked box")
    case _ -> assertTrue(false, "click on a checkbox")
  }
  match Access.resolveRequest(page, t, idOf, "missing", Access.AccessRequest(kind = Access.ReqFocus, text = "")) {
    case Access.Unresolved -> ()
    case _ -> assertTrue(false, "unknown ids do nothing")
  }
  match Access.resolveRequest(page, t, idOf, box.id, Access.AccessRequest(kind = Access.ReqSetValue, text = "x")) {
    case Access.Unresolved -> ()
    case _ -> assertTrue(false, "a checkbox has no value to set")
  }
}

test "ids come from the host and are stable across rebuilds" {
  val wire = toWire(form(newList(), false))
  val page = layoutTree(wire, testEnv(800.0f32, 600.0f32), 0.0f32)
  val idOf = { b: Box -> if b.kind == "page" then "" else refsKey(eventPath(wire, b.path)) + "|" + b.kind }
  val a = Access.buildTree(page, "W", idle(), idOf)
  val b = Access.buildTree(page, "W", idle(), idOf)
  assertEqualInt(a.nodes.count, b.nodes.count, "same size")
  var i = 0
  while i < a.nodes.count {
    assertEqual(a.nodes[i].id, b.nodes[i].id, "same ids")
    i = i + 1
  }
  assertEqual(nodeWith(a, "button").id, "i3;i0;|button", "ids follow the event path")
}

test "a diff carries only the nodes that changed" {
  val before = build(form(newList(), false))
  val same = Access.diffTrees(Some(value = before), build(form(newList(), false)))
  assertEqualInt(same.changed.count, 0, "nothing changed")
  assertEqualInt(same.removed.count, 0, "nothing removed")
  assertTrue(not same.full, "incremental")
  assertTrue(not same.focusChanged, "focus unchanged")
  val toggled = Access.diffTrees(Some(value = before), build(form(newList(), true)))
  assertEqualInt(toggled.changed.count, 1, "only the checkbox")
  assertEqual(Access.roleName(toggled.changed[0].role), "checkbox", "it is the checkbox")
  val first = Access.diffTrees(None, before)
  assertTrue(first.full, "no previous tree: full")
  assertEqualInt(first.changed.count, before.nodes.count, "every node")
}

test "adding and removing nodes shows in the diff" {
  val one: List[View[Msg]] = newList()
  one.add(Widgets.button("A", Hit))
  val two: List[View[Msg]] = newList()
  two.add(Widgets.button("A", Hit))
  two.add(Widgets.button("B", Hit))
  val small = build(Widgets.column(one))
  val big = build(Widgets.column(two))
  val grow = Access.diffTrees(Some(value = small), big)
  assertEqualInt(grow.removed.count, 0, "nothing removed when growing")
  assertTrue(grow.changed.count >= 2, "the root (child list) and the new button")
  val shrink = Access.diffTrees(Some(value = big), small)
  assertEqualInt(shrink.removed.count, 1, "the button is gone")
  assertEqual(shrink.removed[0], idOfNamed(big, "B"), "its id")
}

test "focus moving alone is reported" {
  val page = lay(form(newList(), false))
  val idOf = { b: Box -> noId(b) }
  val a = Access.buildTree(page, "W", idle(), idOf)
  val inputId = nodeWith(a, "textbox").id
  val focused = Access.buildTree(
    page,
    "W",
    Access.AccessState(focusId = inputId, openSelect = "", edit = { id: String -> None }),
    idOf
  )
  val d = Access.diffTrees(Some(value = a), focused)
  assertTrue(d.focusChanged, "focus moved")
  assertEqual(d.focus, inputId, "to the input")
  assertEqualInt(d.changed.count, 0, "no node changed")
}
