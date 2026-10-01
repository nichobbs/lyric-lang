//! tests/grid_tests.l — data grids (docs/65 §13.6, D154): `Ui.Grid` state,
//! the `dataGrid` widget's events through a session, and its first-paint
//! markup.
@test_module
package Ui.GridTests

import Std.Core
import Std.Collections
import Std.String
import Std.Testing
import Ui.Core.{View, Step, RowRange, stay, step1, parseRowRange}
import Ui.Widgets.{dataGrid, gridRow, gridSpec, keyed, text, GridColumn, GridSpec}
import Ui.Diff.{toWire}
import Ui.Html.{renderHtml}
import Ui.Protocol.{Event, NodeRef, At}
import Ui.Grid
import Ui.Grid.{Grid, GridStep, RowQuery, RowPage}
import Ui.Session
import Ui.Session.{Program, Output}

func page(seq: in Int, first: in Int, total: in Int, count: in Int): RowPage[Int] {
  val rows: List[Int] = newList()
  var i = 0
  while i < count {
    rows.add(first + i)
    i += 1
  }
  return RowPage(seq = seq, first = first, total = total, rows = rows)
}

func queryOf(s: in GridStep[Int]): RowQuery {
  return match s.query {
    case Some(q) -> q
    case None -> {
      assertTrue(false, "expected a query")
      RowQuery(seq = 0, first = 0, count = 0, sortColumn = "", ascending = true, filter = "")
    }
  }
}

func hasQuery(s: in GridStep[Int]): Bool {
  return match s.query { case Some(_) -> true; case None -> false }
}

// A grid holding rows 0..49 of 1000.
func loadedGrid(): Grid[Int] {
  val g0: Grid[Int] = Grid.empty(50)
  val s = Grid.start(g0)
  return Grid.loaded(s.grid, page(queryOf(s).seq, 0, 1000, 50))
}

test "row ranges parse from viewport data and reject anything else" {
  match parseRowRange("40,12") {
    case Some(r) -> {
      assertEqualInt(r.first, 40, "first")
      assertEqualInt(r.count, 12, "count")
    }
    case None -> assertTrue(false, "valid range")
  }
  for bad in ["", "1", "1,2,3", "a,2", "-1,2", "1,-2", "0,1001"] {
    match parseRowRange(bad) {
      case Some(_) -> assertTrue(false, "accepted " + bad)
      case None -> ()
    }
  }
}

test "the first page is asked for at start and applied when it arrives" {
  val g0: Grid[Int] = Grid.empty(50)
  val s = Grid.start(g0)
  val q = queryOf(s)
  assertEqualInt(q.first, 0, "from the top")
  assertEqualInt(q.count, 50, "one page")
  val g = Grid.loaded(s.grid, page(q.seq, 0, 1000, 50))
  assertEqualInt(g.total, 1000, "total")
  assertEqualInt(g.rows.count, 50, "rows")
  match Grid.rowAt(g, 49) {
    case Some(v) -> assertEqualInt(v, 49, "row 49")
    case None -> assertTrue(false, "row 49")
  }
  match Grid.rowAt(g, 50) {
    case Some(_) -> assertTrue(false, "row 50 is not loaded")
    case None -> ()
  }
}

test "scrolling within the loaded rows asks for nothing" {
  val s = Grid.viewport(loadedGrid(), RowRange(first = 30, count = 12))
  assertFalse(hasQuery(s), "rows 30..41 are loaded")
}

test "scrolling past the loaded rows asks for a page around them, once" {
  val s = Grid.viewport(loadedGrid(), RowRange(first = 400, count = 10))
  val q = queryOf(s)
  assertEqualInt(q.first, 380, "centred on the viewport")
  assertEqualInt(q.count, 50, "one page")
  val again = Grid.viewport(s.grid, RowRange(first = 402, count = 10))
  assertFalse(hasQuery(again), "already asked for")
  val beyond = Grid.viewport(loadedGrid(), RowRange(first = 995, count = 10))
  assertEqualInt(queryOf(beyond).first, 975, "near the end")
  val past = Grid.viewport(loadedGrid(), RowRange(first = 1200, count = 10))
  assertFalse(hasQuery(past), "past the last row")
}

test "only the page answering the latest query is applied" {
  val g = loadedGrid()
  val first = Grid.viewport(g, RowRange(first = 400, count = 10))
  val second = Grid.viewport(first.grid, RowRange(first = 800, count = 10))
  val stale = Grid.loaded(second.grid, page(queryOf(first).seq, 380, 1000, 50))
  assertEqualInt(stale.first, 0, "the older answer is ignored")
  val fresh = Grid.loaded(second.grid, page(queryOf(second).seq, 780, 1000, 50))
  assertEqualInt(fresh.first, 780, "the latest answer is applied")
}

test "sorting toggles direction and refetches the window; filtering starts over" {
  val g = loadedGrid()
  val byName = Grid.sortBy(g, "name")
  assertEqual(queryOf(byName).sortColumn, "name", "sort column")
  assertTrue(queryOf(byName).ascending, "ascending first")
  val reversed = Grid.sortBy(byName.grid, "name")
  assertFalse(queryOf(reversed).ascending, "then descending")
  assertEqualInt(queryOf(reversed).first, 0, "the loaded window")
  val scrolled = Grid.viewport(g, RowRange(first = 20, count = 10))
  assertFalse(hasQuery(scrolled), "rows 20..29 are loaded")
  assertEqualInt(queryOf(Grid.sortBy(scrolled.grid, "name")).first, 0, "a page around the rows in view")
  val far = Grid.viewport(g, RowRange(first = 600, count = 10))
  assertEqualInt(queryOf(Grid.sortBy(far.grid, "name")).first, 580, "the rows in view, not the loaded window")
  val other = Grid.sortBy(reversed.grid, "city")
  assertTrue(queryOf(other).ascending, "a new column sorts ascending")
  val filtered = Grid.filterBy(Grid.loaded(g, page(0, 500, 1000, 50)), "ac")
  assertEqual(queryOf(filtered).filter, "ac", "filter")
  assertEqualInt(queryOf(filtered).first, 0, "from the top")
}

// ─── The widget through a session ────────────────────────────────────────────
record Model {
  grid: Grid[Int]
  opened: Int
}

union Msg {
  case Scrolled(r: RowRange)
  case Sorted(column: String)
  case Loaded(p: RowPage[Int])
  case Opened(row: Int)
}

union Effect {
  case Fetch(q: RowQuery)
}

func withQuery(m: in Model, s: in GridStep[Int]): Step[Model, Effect] {
  val next = Model(grid = s.grid, opened = m.opened)
  return match s.query {
    case Some(q) -> step1[Model, Effect](next, Fetch(q = q))
    case None -> stay[Model, Effect](next)
  }
}

func update(m: in Model, msg: in Msg): Step[Model, Effect] {
  return match msg {
    case Scrolled(r) -> withQuery(m, Grid.viewport(m.grid, r))
    case Sorted(c) -> withQuery(m, Grid.sortBy(m.grid, c))
    case Loaded(p) -> stay[Model, Effect](Model(grid = Grid.loaded(m.grid, p), opened = m.opened))
    case Opened(row) -> stay[Model, Effect](Model(grid = m.grid, opened = row))
  }
}

func columns(): List[GridColumn] {
  val cs: List[GridColumn] = newList()
  cs.add(GridColumn(id = "n", title = "Number", sortable = true))
  cs.add(GridColumn(id = "sq", title = "Square", sortable = false))
  return cs
}

func view(m: in Model): View[Msg] {
  val g = m.grid
  val rows: List[View[Msg]] = newList()
  var i = 0
  while i < g.rows.count {
    val n = g.rows[i]
    val cells: List[View[Msg]] = newList()
    cells.add(text[Msg](n.toString()))
    cells.add(text[Msg]((n * n).toString()))
    rows.add(keyed[Msg]("r" + n.toString(), gridRow[Msg](cells, Some(value = Opened(row = n)))))
    i += 1
  }
  val spec = gridSpec("Numbers", columns(), g.total, g.first)
  return dataGrid[Msg](
    GridSpec(
      label = spec.label,
      columns = spec.columns,
      sortColumn = g.sortColumn,
      ascending = g.ascending,
      total = spec.total,
      first = spec.first,
      rowHeight = spec.rowHeight,
      visibleRows = spec.visibleRows
    ),
    rows,
    { r: RowRange -> Scrolled(r = r) },
    { c: String -> Sorted(column = c) }
  )
}

func program(): Program[Model, Msg, Effect] {
  return Program(update = update, view = view, uiEffect = { _: Effect -> None })
}

func started(): Output[Model, Msg, Effect] {
  val p = program()
  val o = Session.start(p, stay[Model, Effect](Model(grid = loadedGrid(), opened = -1)))
  return o
}

func at(xs: in slice[Int]): List[NodeRef] {
  val acc: List[NodeRef] = newList()
  for x in xs {
    acc.add(At(index = x))
  }
  return acc
}

func send(
  o: in Output[Model, Msg, Effect], path: in slice[Int], name: in String, data: in String
): Output[Model, Msg, Effect] {
  val ev = Event(renderVersion = o.session.version, path = at(path), name = name, data = data, inputVersion = 0)
  return Session.handleEvent(program(), o.session, ev)
}

test "a viewport event asks the screen for rows; a malformed one is dropped" {
  // Session root column > the grid.
  val o = send(started(), [0], "viewport", "400,10")
  assertFalse(o.dropped, "handled")
  assertEqualInt(o.effects.count, 1, "one fetch")
  match o.effects[0] {
    case Fetch(q) -> assertEqualInt(q.first, 380, "around the viewport")
  }
  val bad = send(started(), [0], "viewport", "400")
  assertTrue(bad.dropped, "malformed viewport data")
}

test "a sort event and a row click reach their handlers" {
  val sorted = send(started(), [0], "sort", "n")
  assertEqualInt(sorted.effects.count, 1, "a refetch")
  assertEqual(sorted.session.model.grid.sortColumn, "n", "sorted by n")
  val clicked = send(started(), [0, 7], "click", "")
  assertEqualInt(clicked.session.model.opened, 7, "row 7 opened")
}

test "the grid's first paint matches the runtime's layout" {
  val g0: Grid[Int] = Grid.empty(2)
  val s = Grid.start(g0)
  val g = Grid.loaded(Grid.sortBy(s.grid, "n").grid, page(2, 3, 6, 2))
  val html = renderHtml(toWire(view(Model(grid = g, opened = -1))))
  assertEqual(
    html,
    "<div class=\"lui-grid\" role=\"grid\" aria-label=\"Numbers\" aria-rowcount=\"7\" aria-colcount=\"2\"" +
      " style=\"--lui-grid-cols:2;--lui-grid-row-height:36px\">" +
      "<div class=\"lui-grid-header\" role=\"rowgroup\"><div class=\"lui-grid-row\" role=\"row\" aria-rowindex=\"1\">" +
      "<div class=\"lui-grid-colheader\" role=\"columnheader\" aria-sort=\"ascending\">" +
      "<button class=\"lui-grid-sort\" type=\"button\">Number</button></div>" +
      "<div class=\"lui-grid-colheader\" role=\"columnheader\">Square</div></div></div>" +
      "<div class=\"lui-grid-body\" tabindex=\"0\" style=\"height:360px\">" +
      "<div class=\"lui-grid-rows\" role=\"rowgroup\" style=\"padding-top:108px;padding-bottom:36px\">" +
      "<div class=\"lui-grid-row\" role=\"row\" tabindex=\"-1\" aria-rowindex=\"5\">" +
      "<div class=\"lui-grid-cell\" role=\"gridcell\">3</div><div class=\"lui-grid-cell\" role=\"gridcell\">9</div></div>" +
      "<div class=\"lui-grid-row\" role=\"row\" tabindex=\"-1\" aria-rowindex=\"6\">" +
      "<div class=\"lui-grid-cell\" role=\"gridcell\">4</div><div class=\"lui-grid-cell\" role=\"gridcell\">16</div></div>" +
      "</div></div></div>",
    "grid markup"
  )
}
