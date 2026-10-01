# D154 — Data grid: a windowed widget whose rows the screen fetches

**Status:** accepted, implemented

Implements docs/65 §13.6 (the third slice of phase U6).

## Context

Line-of-business screens list results far larger than a session should
hold: thousands of customers or orders, sorted and filtered on the
server. §13.6 asked for a grid that renders only the rows in view, with
the host reporting its visible window and the screen fetching rows as
effects.

## Decision

1. **No new protocol messages.** A grid reports through ordinary events
   on its node:
   - `viewport`, with data `"first,count"`, when the rows it shows are not
     all rendered;
   - `sort`, with the column id, when a sortable header is clicked.

   `Handler` gains `OnViewport((RowRange) -> Msg)` and
   `OnSort((String) -> Msg)`. A viewport event that does not parse
   (`Core.parseRowRange`: two non-negative integers, `count` at most
   `maxViewportRows` = 1000) is dropped by the session (`Core.accepts`),
   so a host cannot make a screen fetch an unbounded window.
2. **The screen owns the data; `Ui.Grid` owns the bookkeeping.**
   `Grid[Row]` (pure, in the logic layer) holds:
   - the loaded window (`first`, `rows`, `total`);
   - the sort and filter;
   - the outstanding query.

   `viewport`, `sortBy`, `filterBy` and `refresh` return a `GridStep`
   with an optional `RowQuery`, which `update` turns into the screen's
   own fetch effect. Effects stay screen data, as for every other effect
   (D137). A viewport already loaded or already asked for issues no
   query; a new one asks for a page (`pageSize`, or the viewport if
   larger) centred on it.
3. **Only the latest answer applies.** Every query carries a sequence
   number. `loaded` applies only the `RowPage` answering the latest
   query, so a slow response never overwrites a newer one. Sorting and
   filtering take effect at once, and the loaded rows stay on screen until
   the answer arrives.
4. **One window, replaced.** The session holds the rows of the last page
   only, never an accumulating cache. Diffing patches the rendered rows,
   which are keyed by the screen, so a page that overlaps the previous
   one moves rows rather than rebuilding them.
5. **Rendering.** `Widgets.dataGrid(spec, rows, onViewport, onSort)`
   carries the spec as props:
   - `rowCount`, `firstRow`, `rowHeight` and `visibleRows`;
   - `columns`, a JSON array of `{id, title, sort}`.

   The host renders a header row, then a scrolling body whose padding
   stands in for the rows not rendered, so the scrollbar spans every row.
   Rows have a fixed height.
   - **ARIA:** `role="grid"`, `aria-rowcount`, `aria-rowindex` and
     `aria-sort`.
   - **Keyboard:** the arrow keys move between rows, and Enter or Space
     activates a row. `Ui.Html` renders the same structure for the first
     paint.
6. **Layers.** The `ui` preset lets logic, effects and views import
   `Ui.Grid`, as they import `Ui.Core` and `Ui.Routing`.

## Consequences

- `WidgetKind` gains `DataGrid`, `GridRow` and `GridCell`, and `Handler`
  gains two cases, so exhaustive matches over either must handle them.
- Variable row heights, column resizing and in-grid editing are not
  covered. Each would be a new prop or event on the same widget.
- `examples/ui-customers` lists its 200 demo customers in a grid, sorted
  by the repository (`CustomerRepository.page`). The browser test sorts
  and scrolls it on both targets.

## Also in this change: D153 follow-ups

From the review of D153 (`Lazy` subtrees):

- **Duplicate keys in the current render.** A `Lazy` key duplicated for
  the first time in the current render was looked up against the single
  previous memo at both positions. The session now also collects the
  current tree's `Lazy` keys (`collectLazyKeys`) and the keys met while
  resolving, so a key repeated in either tree is rendered at every
  position, as D153 item 4 states.
- **Wording.** The docs no longer say an unchanged lazy subtree "costs
  nothing": it is neither rendered nor diffed, but the session still
  walks it once per update to find its memos.
