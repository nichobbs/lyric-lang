//! Customers.Edit.Effects — runs the edit screen's effects against the
//! ports (docs/65-ui-library-sketch.md §4.2).
//!
//! Layer: effects.  The only code for this screen that performs I/O.  UI
//! effects (navigation, dialogs, toasts) never reach here: the session
//! runtime interprets them.
@runtime_checked
package Customers.Edit.Effects

import Std.Core
import Customers.Ports.{CustomerRepository}
import Customers.Edit.Logic.{Effect, Msg, LoadCustomer, SaveCustomer, Ui, Loaded, Saved}

pub async func run(e: in Effect, repo: in CustomerRepository): Option[Msg] {
  return match e {
    case LoadCustomer(id) -> Some(value = Loaded(outcome = await repo.find(id)))
    case SaveCustomer(c) -> Some(value = Saved(outcome = await repo.save(c)))
    case Ui(_) -> None
  }
}
