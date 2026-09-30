//! Customers.List.View — presentation of the customer list
//! (docs/65-ui-library-sketch.md §4.3).
//!
//! Layer: view.  Builds `View` values from the model; never performs I/O.
@runtime_checked
package Customers.List.View

import Std.Core
import Std.Collections
import Ui.Core.{View}
import Ui.Widgets
import Customers.Domain.{Customer, tierLabel}
import Customers.List.Logic.{Model, Msg, Status, Loading, Loaded, LoadFailed, RetryClicked}

pub func view(m: in Model): View[Msg] {
  return match m.status {
    case Loading -> Widgets.spinner("Loading customers")
    case LoadFailed(message) -> {
      val cs: List[View[Msg]] = newList()
      cs.add(Widgets.banner("error", "Could not load the customers: " + message))
      cs.add(Widgets.button("Retry", RetryClicked))
      Widgets.column(cs)
    }
    case Loaded(customers) -> listing(customers)
  }
}

func listing(customers: in List[Customer]): View[Msg] {
  val headers: List[String] = newList()
  headers.add("Name")
  headers.add("Email")
  headers.add("Tier")
  val rows: List[View[Msg]] = newList()
  for c in customers {
    val cells: List[View[Msg]] = newList()
    cells.add(Widgets.link(c.name, "/customers/" + c.id.toString()))
    cells.add(Widgets.text(c.email))
    cells.add(Widgets.text(tierLabel(c.tier)))
    rows.add(Widgets.keyed(c.id.toString(), Widgets.tableRow(cells, None)))
  }
  val page: List[View[Msg]] = newList()
  page.add(Widgets.heading(1, "Customers"))
  page.add(Widgets.table(headers, rows))
  return Widgets.column(page)
}
