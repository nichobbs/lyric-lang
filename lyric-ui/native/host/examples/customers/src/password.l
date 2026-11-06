//! password.l - Customers.Native.Password: one password input, for the native check run's password
//! scenario (#8817).  The customers example has no password field, and the scenario needs a screen
//! whose value it can set and read back without touching the example's own packages.
package Customers.Native.Password

import Std.Core
import Std.Collections
import Ui.Core.{View, Step, stay}
import Ui.Host.{Instance, instance}
import Ui.Session.{Program}
import Ui.Widgets

pub record Model {
  secret: String
}

pub union Msg {
  case Typed(s: String)
}

pub union Effect {
  case NoEffect
}

func update(m: Model, msg: Msg): Step[Model, Effect] {
  match msg {
    case Typed(s) -> stay(m.copy(secret = s))
  }
}

func view(m: Model): View[Msg] {
  val kids: List[View[Msg]] = newList()
  kids.add(Widgets.textInput("password", m.secret, { s: String -> Typed(s = s) }, Widgets.inputOpts()))
  Widgets.column(kids)
}

/// The password screen, starting empty.
pub func screen(): Instance {
  val p = Program(update = update, view = view, uiEffect = { e: Effect -> None })
  instance(p, stay(Model(secret = "")), { e: Effect -> None })
}
