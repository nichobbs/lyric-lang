//! Customers.List.Logic — the customer list as a pure state machine
//! (docs/65-ui-library-sketch.md §4.1).
//!
//! Layer: logic.  The page the edit screen returns to after a save or a
//! cancel.  The listing is a data grid (docs/65 §13.6): `Ui.Grid` keeps the
//! loaded window and turns scrolling and sorting into row queries, which
//! this screen runs as `FetchRows` effects.  A failed fetch offers a retry.
@runtime_checked
package Customers.List.Logic

import Std.Core
import Std.Collections
import Ui.Core.{Step, UiEffect, RowRange, stay, step1}
import Ui.Grid
import Ui.Grid.{Grid, GridStep, RowQuery, RowPage}
import Customers.Domain.{Customer, CustomerOrder, CustomerPage}

/// Rows fetched per query.
pub val pageSize: Int = 50

pub union Status {
  case Loading
  case Ready
  case LoadFailed(message: String)
}

pub record Model {
  grid: Grid[Customer]
  status: Status
}

pub union Msg {
  case RowsLoaded(seq: Int, first: Int, outcome: Result[CustomerPage, String])
  case Scrolled(range: RowRange)
  case Sorted(column: String)
  case RetryClicked
}

pub union Effect {
  case FetchRows(query: RowQuery)
  case Ui(effect: UiEffect[Msg])
}

pub func init(): Step[Model, Effect] {
  val empty: Grid[Customer] = Grid.empty(pageSize)
  return withQuery(Status.Loading, Grid.start(empty))
}

pub func update(m: in Model, msg: in Msg): Step[Model, Effect] {
  return match msg {
    case RowsLoaded(seq, first, outcome) -> loaded(m, seq, first, outcome)
    case Scrolled(r) -> withQuery(m.status, Grid.viewport(m.grid, r))
    case Sorted(column) -> withQuery(m.status, Grid.sortBy(m.grid, column))
    case RetryClicked -> withQuery(Status.Loading, Grid.refresh(m.grid))
  }
}

/// The listing order for a grid column id; the natural (id) order for
/// none.
pub func orderFor(column: in String): CustomerOrder {
  return if column == "name" then CustomerOrder.ByName else if column == "email" then CustomerOrder.ByEmail else if column == "tier" then CustomerOrder.ByTier else CustomerOrder.ById
}

/// True when the screen's effect is one the UI runtime handles
/// (`Program.uiEffect`).
pub func uiEffect(e: in Effect): Option[UiEffect[Msg]] {
  return match e { case Ui(u) -> Some(value = u); case _ -> None }
}

// The answer to the latest query fills the grid; a failure is reported
// unless a newer query has replaced it.
func loaded(m: in Model, seq: in Int, first: in Int, outcome: in Result[CustomerPage, String]): Step[Model, Effect] {
  if seq != m.grid.seq {
    return stay(m)
  }
  return match outcome {
    case Ok(p) -> {
      val page: RowPage[Customer] = RowPage(seq = seq, first = first, total = p.total, rows = p.customers)
      stay(Model(grid = Grid.loaded(m.grid, page), status = Status.Ready))
    }
    case Err(e) -> stay(Model(grid = m.grid, status = Status.LoadFailed(message = e)))
  }
}

func withQuery(status: in Status, s: in GridStep[Customer]): Step[Model, Effect] {
  val next = Model(grid = s.grid, status = status)
  return match s.query { case Some(q) -> step1(next, FetchRows(query = q)); case None -> stay(next) }
}
