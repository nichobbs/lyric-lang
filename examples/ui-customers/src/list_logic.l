//! Customers.List.Logic — the customer list as a pure state machine
//! (docs/65-ui-library-sketch.md §4.1).
//!
//! Layer: logic.  The page the edit screen returns to after a save or a
//! cancel.  Loads every customer once, and offers a retry when loading
//! fails.
@runtime_checked
package Customers.List.Logic

import Std.Core
import Std.Collections
import Ui.Core.{Step, UiEffect, stay, step1}
import Customers.Domain.{Customer}

pub union Status {
  case Loading
  case Loaded(customers: List[Customer])
  case LoadFailed(message: String)
}

pub record Model {
  status: Status
}

pub union Msg {
  case CustomersLoaded(outcome: Result[List[Customer], String])
  case RetryClicked
}

pub union Effect {
  case LoadCustomers
  case Ui(effect: UiEffect[Msg])
}

pub func init(): Step[Model, Effect] {
  return step1(Model(status = Status.Loading), LoadCustomers)
}

pub func update(m: in Model, msg: in Msg): Step[Model, Effect] {
  return match msg {
    case CustomersLoaded(Ok(cs)) -> stay(Model(status = Status.Loaded(customers = cs)))
    case CustomersLoaded(Err(e)) -> stay(Model(status = Status.LoadFailed(message = e)))
    case RetryClicked -> step1(Model(status = Status.Loading), LoadCustomers)
  }
}

/// True when the screen's effect is one the UI runtime handles
/// (`Program.uiEffect`).
pub func uiEffect(e: in Effect): Option[UiEffect[Msg]] {
  return match e { case Ui(u) -> Some(value = u); case _ -> None }
}
