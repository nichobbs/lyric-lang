//! Customers.App - the application's composition below the host: binds the repository to the screens
//! and maps a URL to the instance of its screen.  Every host (`Ui.Host.Web`, `Ui.Host.Desktop`,
//! `Ui.Native.Run`) takes `route` as it is, so the application is written once.
//!
//! Layer: app.
@runtime_checked
package Customers.App

import Std.Core
import Ui.Host.{Instance, instance}
import Ui.Session.{Program}
import Customers.Domain.{CustomerId}
import Customers.Ports.{CustomerRepository}
import Customers.Routes.{Route, CustomerList, EditCustomer, parseRoute}
import Customers.Edit.Logic
import Customers.Edit.Effects
import Customers.Edit.View
import Customers.List.Logic as ListLogic
import Customers.List.Effects as ListEffects
import Customers.List.View as ListView

/// The screen instance for `url`, or `None` for an unknown page.
pub func route(repo: in CustomerRepository, url: in String): Option[Instance] {
  return match parseRoute(url) { case Some(r) -> Some(value = screenFor(repo, r)); case None -> None }
}

// Exhaustive over `Route`, so a page without a screen does not compile.
func screenFor(repo: in CustomerRepository, r: in Route): Instance {
  return match r { case CustomerList -> listScreen(repo); case EditCustomer(id) -> editScreen(repo, id) }
}

func listScreen(repo: in CustomerRepository): Instance {
  val p = Program(update = ListLogic.update, view = ListView.view, uiEffect = ListLogic.uiEffect)
  return instance(p, ListLogic.init(), { e: ListLogic.Effect -> ListEffects.run(e, repo) })
}

func editScreen(repo: in CustomerRepository, id: in CustomerId): Instance {
  val p = Program(update = Logic.update, view = View.view, uiEffect = Logic.uiEffect)
  return instance(p, Logic.init(id), { e: Logic.Effect -> Effects.run(e, repo) })
}
