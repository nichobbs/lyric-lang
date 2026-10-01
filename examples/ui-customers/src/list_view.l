//! Customers.List.View — presentation of the customer list
//! (docs/65-ui-library-sketch.md §4.3).
//!
//! Layer: view.  Builds `View` values from the model; never performs I/O.
@runtime_checked
package Customers.List.View

import Std.Core
import Std.Collections
import Ui.Core.{View, RowRange}
import Ui.Widgets
import Ui.Widgets.{GridColumn}
import Customers.Domain.{Customer, tierLabel}
import Customers.Routes.{EditCustomer, routeUrl}
import Customers.List.Logic.{Model, Msg, Status, Loading, Ready, LoadFailed, RetryClicked, Scrolled, Sorted}

pub func view(m: in Model): View[Msg] {
  return match m.status {
    case Loading -> Widgets.spinner("Loading customers")
    case LoadFailed(message) -> {
      val cs: List[View[Msg]] = newList()
      cs.add(Widgets.banner("error", "Could not load the customers: " + message))
      cs.add(Widgets.button("Retry", RetryClicked))
      Widgets.column(cs)
    }
    case Ready -> listing(m)
  }
}

func columns(): List[GridColumn] {
  val cs: List[GridColumn] = newList()
  cs.add(GridColumn(id = "name", title = "Name", sortable = true))
  cs.add(GridColumn(id = "email", title = "Email", sortable = true))
  cs.add(GridColumn(id = "tier", title = "Tier", sortable = true))
  return cs
}

func listing(m: in Model): View[Msg] {
  val g = m.grid
  val rows: List[View[Msg]] = newList()
  for c in g.rows {
    val cells: List[View[Msg]] = newList()
    cells.add(Widgets.link(c.name, routeUrl(EditCustomer(id = c.id))))
    cells.add(Widgets.text(c.email))
    cells.add(Widgets.text(tierLabel(c.tier)))
    rows.add(Widgets.keyed(c.id.toString(), Widgets.gridRow(cells, None)))
  }
  val spec = Widgets.gridSpec("Customers", columns(), g.total, g.first).copy(
    sortColumn = g.sortColumn,
    ascending = g.ascending
  )
  val page: List[View[Msg]] = newList()
  page.add(Widgets.heading(1, "Customers"))
  page.add(Widgets.dataGrid(spec, rows, { r: RowRange -> Scrolled(range = r) }, { c: String -> Sorted(column = c) }))
  return Widgets.column(page)
}
