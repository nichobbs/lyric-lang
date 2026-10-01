//! Customers — composition root: binds the repository, maps URLs to screens
//! and starts the server-driven web host.
//!
//! Layer: app.  The only package that sees every layer.
//!
//! Run:  lyric run --manifest examples/ui-customers/lyric.toml
//! Open: http://localhost:8080/customers
@runtime_checked
package Customers

import Std.Core
import Std.Console
import Ui.Host.{Instance, instance}
import Ui.Host.Web as WebHost
import Ui.Session.{Program}
import Customers.Domain.{CustomerId}
import Customers.Ports.{CustomerRepository}
import Customers.Routes.{Route, CustomerList, EditCustomer, parseRoute}
import Customers.Store
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

func main(): Unit {
  val repo = Store.seeded()
  val cfg = WebHost.defaultConfig("Customers")
  println("Customers: http://localhost:" + cfg.port.toString() + "/customers")
  match WebHost.serve(cfg, { url: String -> route(repo, url) }) {
    case Ok(_) -> ()
    case Err(e) -> Console.error("Customers: could not start: " + e)
  }
}
