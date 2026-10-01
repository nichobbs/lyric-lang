//! Customers.List.Effects — runs the list screen's effects against the
//! ports (docs/65-ui-library-sketch.md §4.2).
//!
//! Layer: effects.  The only code for this screen that performs I/O.
@runtime_checked
package Customers.List.Effects

import Std.Core
import Customers.Ports.{CustomerRepository}
import Customers.List.Logic.{Effect, Msg, FetchRows, Ui, RowsLoaded, orderFor}

pub async func run(e: in Effect, repo: in CustomerRepository): Option[Msg] {
  return match e {
    case FetchRows(q) -> {
      val outcome = await repo.page(q.first, q.count, orderFor(q.sortColumn), q.ascending)
      Some(value = RowsLoaded(seq = q.seq, first = q.first, outcome = outcome))
    }
    case Ui(_) -> None
  }
}
