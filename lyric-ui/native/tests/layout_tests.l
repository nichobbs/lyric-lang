@test_module
package Ui.Native.LayoutTests

import Std.Core
import Std.Collections
import Std.Testing
import Ui.Core.{View, Prop}
import Ui.Diff.{WireNode, WElement, WText, WEmpty, toWire}
import Ui.Widgets
import Ui.Widgets.{GridColumn}
import Ui.Native.Layout
import Ui.Native.Layout.{Box, layoutTree, testEnv}

union Msg {
  case Hit
  case Typed(s: String)
  case Sorted(c: String)
  case Scrolled(r: Ui.Core.RowRange)
}

func lay(v: View[Msg], width: Float): Box {
  layoutTree(toWire(v), testEnv(width, 600.0f32), 0.0f32)
}

// The page's one child: the app tree's root box.
func app(page: Box): Box {
  page.children[0]
}

func near(a: Float, b: Float): Bool {
  val d = a - b
  d < 0.01f32 and d > -0.01f32
}

func kinds(b: Box): List[String] {
  val acc: List[String] = newList()
  for c in b.children {
    acc.add(c.kind)
  }
  acc
}

test "the page is centred in its maximum width with the page padding" {
  val page = lay(Widgets.paragraph("hi"), 1400.0f32)
  val p = app(page)
  assertTrue(near(p.x, 220.0f32 + 16.0f32), "x: (1400 - 960) / 2 + 16")
  assertTrue(near(p.w, 960.0f32 - 32.0f32), "width")
  assertTrue(near(p.y, 24.0f32), "y")
  val narrow = lay(Widgets.paragraph("hi"), 400.0f32)
  assertTrue(near(app(narrow).x, 16.0f32), "no centring below the maximum")
}

test "a column stacks its children with the gap" {
  val kids: List[View[Msg]] = newList()
  kids.add(Widgets.heading(1, "Title"))
  kids.add(Widgets.paragraph("body"))
  kids.add(Widgets.button("Go", Hit))
  val c = app(lay(Widgets.column(kids), 800.0f32))
  assertEqualInt(c.children.count, 3, "children")
  assertTrue(near(c.children[1].y, c.children[0].y + c.children[0].h + 12.0f32), "gap after the heading")
  assertTrue(near(c.children[2].y, c.children[1].y + c.children[1].h + 12.0f32), "gap after the paragraph")
  assertTrue(near(c.h, c.children[2].y + c.children[2].h - c.y), "column height")
  assertTrue(near(c.children[0].h, 20.0f32 * 1.8f32), "level one heading is tall")
}

test "a paragraph wraps to the available width" {
  val narrow = app(lay(Widgets.paragraph("aaaa bbbb cccc dddd"), 232.0f32))
  // 200 px of content = 25 characters at 8 px: fits on one line.
  assertTrue(near(narrow.h, 20.0f32), "one line")
  val wrapped = app(lay(Widgets.paragraph("aaaa bbbb cccc dddd eeee ffff gggg hhhh"), 232.0f32))
  assertTrue(wrapped.h > 20.0f32, "wraps")
}

test "a row flows left to right and wraps" {
  val kids: List[View[Msg]] = newList()
  kids.add(Widgets.button("One", Hit))
  kids.add(Widgets.button("Two", Hit))
  val r = app(lay(Widgets.row(kids), 800.0f32))
  assertTrue(near(r.children[0].y, r.children[1].y), "same line")
  assertTrue(near(r.children[1].x, r.children[0].x + r.children[0].w + 12.0f32), "gap")
  val many: List[View[Msg]] = newList()
  var i = 0
  while i < 6 {
    many.add(Widgets.button("A long label " + i.toString(), Hit))
    i = i + 1
  }
  val wrapped = app(lay(Widgets.row(many), 500.0f32))
  assertTrue(wrapped.children[5].y > wrapped.children[0].y, "wraps onto another line")
  assertTrue(wrapped.h > 36.0f32, "taller than one line")
}

test "a spacer pushes what follows it to the right edge" {
  val kids: List[View[Msg]] = newList()
  kids.add(Widgets.button("Left", Hit))
  kids.add(Ui.Widgets.element(Ui.Core.WidgetKind.Spacer, Widgets.noProps(), newList(), newList()))
  kids.add(Widgets.button("Right", Hit))
  val r = app(lay(Widgets.row(kids), 600.0f32))
  val right = r.children[2]
  assertTrue(near(right.x + right.w, r.x + r.w), "right edge")
}

test "a card has padding, a title and a body" {
  val kids: List[View[Msg]] = newList()
  kids.add(Widgets.paragraph("inside"))
  val c = app(lay(Widgets.card("Details", kids), 600.0f32))
  assertEqual(kinds(c)[0], "cardTitle", "title first")
  assertEqual(kinds(c)[1], "cardBody", "then the body")
  assertTrue(near(c.children[0].x, c.x + 17.0f32), "inside the border and padding")
  assertTrue(c.h > c.children[1].h + 34.0f32 - 0.1f32, "padding around the body")
}

test "a field puts its label above the control and errors below" {
  val errs: List[String] = newList()
  errs.add("Required")
  val f = app(
    lay(
      Widgets.field(
        "Name",
        errs,
        Widgets.textInput("text", "", { s: String -> Typed(s = s) }, Widgets.inputOpts())
      ),
      600.0f32
    )
  )
  assertEqual(kinds(f)[0], "fieldLabel", "label")
  val body = f.children[1]
  assertEqual(body.children[0].kind, "textInput", "control")
  assertEqual(body.children[1].kind, "fieldError", "error")
  assertTrue(body.children[1].y > body.children[0].y, "error below the control")
  assertTrue(body.children[0].focusable, "inputs take focus")
}

test "buttons size to their label and a blocked button cannot take focus" {
  val b = app(lay(Widgets.button("Save", Hit), 600.0f32))
  assertTrue(near(b.w, 4.0f32 * 8.0f32 * 1.0f32 + 30.0f32), "label width plus padding")
  assertTrue(b.focusable, "enabled")
  val busy = app(lay(Widgets.primaryButton("Save", Hit, true), 600.0f32))
  assertTrue(not busy.focusable, "busy")
}

test "a dialog covers the window and does not take room in the flow" {
  val kids: List[View[Msg]] = newList()
  kids.add(Widgets.paragraph("page"))
  val dialogKids: List[View[Msg]] = newList()
  dialogKids.add(Widgets.paragraph("Delete it?"))
  kids.add(Ui.Widgets.element(Ui.Core.WidgetKind.Dialog, Widgets.noProps(), newList(), dialogKids))
  kids.add(Widgets.paragraph("after"))
  val page = lay(Widgets.column(kids), 800.0f32)
  val c = app(page)
  assertEqual(c.children[1].kind, "dialog", "dialog box")
  assertTrue(near(c.children[1].w, 800.0f32) and near(c.children[1].h, 600.0f32), "covers the window")
  assertTrue(
    near(c.children[2].y, c.children[0].y + c.children[0].h + 12.0f32),
    "after follows the page paragraph directly"
  )
  val panel = c.children[1].children[0]
  assertEqual(panel.kind, "dialogPanel", "panel")
  assertTrue(panel.x > 0.0f32 and panel.x + panel.w < 800.0f32, "panel centred")
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

test "a data grid has a header, a body sized by visible rows, and rows at their absolute position" {
  val g = app(lay(gridView(5, 100, 8), 800.0f32))
  assertEqual(g.kind, "dataGrid", "grid")
  assertEqual(g.children[0].kind, "colheader", "header cells first")
  assertEqual(g.children[0].text, "Name", "title")
  assertTrue(g.children[0].focusable, "a sortable column is a control")
  assertTrue(not g.children[1].focusable, "an unsortable column is not")
  val body = g.children[2]
  assertEqual(body.kind, "gridBody", "body")
  assertTrue(near(body.h, 10.0f32 * 36.0f32), "ten visible rows of 36")
  assertTrue(near(body.contentHeight, 100.0f32 * 36.0f32), "scroll range covers every row")
  assertEqualInt(body.children.count, 8, "loaded rows")
  assertTrue(near(body.children[0].y, body.y + 5.0f32 * 36.0f32), "first loaded row sits at its absolute index")
  assertTrue(near(body.children[1].y - body.children[0].y, 36.0f32), "row height")
}

test "grid scroll moves the rows" {
  val env = testEnv(800.0f32, 600.0f32).copy(gridScroll = { p: List[Int] -> 72.0f32 })
  val page = layoutTree(toWire(gridView(0, 100, 10)), env, 0.0f32)
  val body = app(page).children[2]
  assertTrue(near(body.children[0].y, body.y - 72.0f32), "row 0 scrolled up by two rows")
}

test "a table sizes its columns to their content" {
  val rows: List[View[Msg]] = newList()
  val c1: List[View[Msg]] = newList()
  c1.add(Widgets.text("a"))
  c1.add(Widgets.text("a much longer cell"))
  rows.add(Widgets.tableRow(c1, None))
  val headers: List[String] = newList()
  headers.add("H1")
  headers.add("H2")
  val t = app(lay(Widgets.table(headers, rows), 600.0f32))
  assertEqual(t.kind, "table", "table")
  val header = t.children[0]
  assertTrue(header.children[1].w > header.children[0].w, "the longer column is wider")
  assertTrue(near(header.children[0].w + header.children[1].w, 568.0f32), "columns fill the table")
}

test "layout is deterministic" {
  val v = gridView(0, 20, 5)
  val a = lay(v, 700.0f32)
  val b = lay(v, 700.0f32)
  assertTrue(near(a.contentHeight, b.contentHeight), "same height")
  assertEqualInt(a.children[0].children.count, b.children[0].children.count, "same boxes")
}
