//! Ui.Grid — the state behind a data grid (docs/65-ui-library-sketch.md
//! §13.6, D154).
//!
//! A grid shows a window of a result that may be far larger than what the
//! session holds.  `Grid[Row]` keeps the loaded window and the current sort
//! and filter; the functions here turn the grid's events into `RowQuery`
//! values, which the screen's `update` returns as its own fetch effect, and
//! take the resulting `RowPage` back.  Every query carries a sequence
//! number, and only the page answering the latest query is applied, so a
//! slow response never overwrites a newer one.
//!
//!   case Scrolled(r) -> {
//!     val s = Grid.viewport(m.grid, r)
//!     withQuery(m.copy(grid = s.grid), s.query)   // FetchRows effect, if any
//!   }
//!   case RowsLoaded(page) -> stay(m.copy(grid = Grid.loaded(m.grid, page)))
@runtime_checked
@pure
package Ui.Grid

import Std.Core
import Std.Collections
import Ui.Core.{RowRange}

/// A request for `count` rows from index `first` of the result sorted by
/// `sortColumn` (empty for the natural order) and narrowed by `filter`.
/// Answer it with a `RowPage` carrying the same `seq`.
pub record RowQuery {
  seq: Int
  first: Int
  count: Int
  sortColumn: String
  ascending: Bool
  filter: String
}

/// The answer to a query: `rows` from index `first`, out of `total` rows in
/// the whole result.  `rows` may be shorter than asked for at the end.
pub record RowPage[Row] {
  seq: Int
  first: Int
  total: Int
  rows: List[Row]
}

/// A grid's state: the loaded rows (from index `first`, of `total`), the
/// sort and filter they were fetched with, the rows the host last reported
/// showing (`visible`, empty until it reports), and the outstanding query
/// (`requested`, empty when none).
pub record Grid[Row] {
  total: Int
  first: Int
  rows: List[Row]
  sortColumn: String
  ascending: Bool
  filter: String
  pageSize: Int
  seq: Int
  visible: RowRange
  requested: RowRange
}

/// A grid after an event, and the query to run, if any.
pub record GridStep[Row] {
  grid: Grid[Row]
  query: Option[RowQuery]
}

/// An empty grid that fetches `pageSize` rows at a time.
pub func empty[Row](pageSize: in Int): Grid[Row]
  requires: pageSize > 0
{
  val none: List[Row] = newList()
  return Grid(
    total = 0,
    first = 0,
    rows = none,
    sortColumn = "",
    ascending = true,
    filter = "",
    pageSize = pageSize,
    seq = 0,
    visible = RowRange(first = 0, count = 0),
    requested = RowRange(first = 0, count = 0)
  )
}

/// The query for the first page, as a screen's `init` runs it.
pub func start[Row](g: in Grid[Row]): GridStep[Row] {
  return query(g, 0, g.pageSize, g.sortColumn, g.ascending, g.filter)
}

/// The grid now shows rows `r`.  Asks for a page around them unless they
/// are loaded or already asked for.
pub func viewport[Row](g: in Grid[Row], r: in RowRange): GridStep[Row] {
  val seen = withVisible(g, r)
  val upTo = if r.first + r.count < g.total then r.first + r.count else g.total
  if upTo <= r.first or covers(g.first, g.rows.count, r.first, upTo) or covers(g.requested.first, g.requested.count, r.first, upTo) {
    return noQuery(seen)
  }
  val w = around(g, r)
  return query(seen, w.first, w.count, g.sortColumn, g.ascending, g.filter)
}

/// A click on sortable column `column`: sorts by it ascending, or reverses
/// the direction when it is already the sort column.  The rows in view
/// are fetched again in the new order.
pub func sortBy[Row](g: in Grid[Row], column: in String): GridStep[Row] {
  val ascending = if column == g.sortColumn then not g.ascending else true
  val w = currentWindow(g)
  return query(g, w.first, w.count, column, ascending, g.filter)
}

/// Narrows the result to `filter`, from the first row.
pub func filterBy[Row](g: in Grid[Row], filter: in String): GridStep[Row] {
  return query(g, 0, g.pageSize, g.sortColumn, g.ascending, filter)
}

/// Fetches the rows in view again, after the underlying rows changed.
pub func refresh[Row](g: in Grid[Row]): GridStep[Row] {
  val w = currentWindow(g)
  return query(g, w.first, w.count, g.sortColumn, g.ascending, g.filter)
}

/// Applies `page` when it answers the latest query; any other page is
/// stale and ignored.
pub func loaded[Row](g: in Grid[Row], page: in RowPage[Row]): Grid[Row] {
  if page.seq != g.seq {
    return g
  }
  val total = if page.total >= 0 then page.total else 0
  val next: Grid[Row] = Grid(
    total = total,
    first = page.first,
    rows = page.rows,
    sortColumn = g.sortColumn,
    ascending = g.ascending,
    filter = g.filter,
    pageSize = g.pageSize,
    seq = g.seq,
    visible = g.visible,
    requested = RowRange(first = 0, count = 0)
  )
  return next
}

/// Row `index` of the result, when it is loaded.
pub func rowAt[Row](g: in Grid[Row], index: in Int): Option[Row] {
  val i = index - g.first
  if i < 0 or i >= g.rows.count {
    return None
  }
  return Some(value = g.rows[i])
}

/// Whether rows `[first, upTo)` lie within the `count` rows from `from`.
pub func covers(from: in Int, count: in Int, first: in Int, upTo: in Int): Bool {
  return count > 0 and first >= from and upTo <= from + count
}

/// The rows to fetch for a page around `r`: `pageSize` rows, or `r` if it
/// is larger, centred on `r`.
pub func around[Row](g: in Grid[Row], r: in RowRange): RowRange {
  val count = if r.count > g.pageSize then r.count else g.pageSize
  val before = (count - r.count) / 2
  val first = if r.first > before then r.first - before else 0
  return RowRange(first = first, count = count)
}

/// The rows to fetch to replace what is in view: a page around the
/// reported viewport, or the loaded window before the host has reported.
pub func currentWindow[Row](g: in Grid[Row]): RowRange {
  if g.visible.count > 0 {
    return around(g, g.visible)
  }
  val count = if g.rows.count > g.pageSize then g.rows.count else g.pageSize
  return RowRange(first = g.first, count = count)
}

/// `g` with `r` as the rows in view.
pub func withVisible[Row](g: in Grid[Row], r: in RowRange): Grid[Row] {
  val next: Grid[Row] = Grid(
    total = g.total,
    first = g.first,
    rows = g.rows,
    sortColumn = g.sortColumn,
    ascending = g.ascending,
    filter = g.filter,
    pageSize = g.pageSize,
    seq = g.seq,
    visible = r,
    requested = g.requested
  )
  return next
}

/// `g` with no query to run.
pub func noQuery[Row](g: in Grid[Row]): GridStep[Row] {
  val none: Option[RowQuery] = None
  return GridStep(grid = g, query = none)
}

/// `g` waiting on a new query for `count` rows from `first`, sorted and
/// filtered as given.  The sort and filter take effect at once, so later
/// queries use them, and the loaded rows stay on screen until the answer
/// arrives.
pub func query[Row](
  g: in Grid[Row],
  first: in Int,
  count: in Int,
  sortColumn: in String,
  ascending: in Bool,
  filter: in String,
): GridStep[Row] {
  val seq = g.seq + 1
  val next: Grid[Row] = Grid(
    total = g.total,
    first = g.first,
    rows = g.rows,
    sortColumn = sortColumn,
    ascending = ascending,
    filter = filter,
    pageSize = g.pageSize,
    seq = seq,
    visible = g.visible,
    requested = RowRange(first = first, count = count)
  )
  val q = RowQuery(
    seq = seq,
    first = first,
    count = count,
    sortColumn = sortColumn,
    ascending = ascending,
    filter = filter
  )
  return GridStep(grid = next, query = Some(value = q))
}
