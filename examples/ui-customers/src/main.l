//! Customers — composition root: binds the repository, maps URLs to screens
//! and starts the server-driven web host.
//!
//! Layer: app.  The only package that sees every layer.
//!
//! Run:  lyric run --manifest examples/ui-customers/lyric.toml
//! Open: http://localhost:8080/customers/1
@runtime_checked
package Customers

import Std.Core
import Std.Console
import Std.String
import Std.Parse
import Ui.Host.{Instance, instance}
import Ui.Host.Web as WebHost
import Ui.Session.{Program}
import Customers.Domain.{CustomerId}
import Customers.Ports.{CustomerRepository}
import Customers.Store
import Customers.Edit.Logic
import Customers.Edit.Effects
import Customers.Edit.View

/// The screen instance for `url`, or `None` for an unknown page.
pub func route(repo: in CustomerRepository, url: in String): Option[Instance] {
  val prefix = "/customers/"
  if startsWith(url, prefix) {
    return match parseOptLong(substring(url, prefix.length)) {
      case Some(n) ->
        match CustomerId.tryFrom(n) {
          case Ok(id) -> Some(value = editScreen(repo, id))
          case Err(_) -> None
        }
      case None -> None
    }
  }
  return None
}

func editScreen(repo: in CustomerRepository, id: in CustomerId): Instance {
  val p = Program(update = Logic.update, view = View.view, uiEffect = Logic.uiEffect)
  return instance(p, Logic.init(id), { e: Logic.Effect -> Effects.run(e, repo) })
}

func main(): Unit {
  val repo = Store.seeded()
  val cfg = WebHost.defaultConfig("Customers")
  println("Customers: http://localhost:" + cfg.port.toString() + "/customers/1")
  match WebHost.serve(cfg, { url: String -> route(repo, url) }) {
    case Ok(_) -> ()
    case Err(e) -> Console.error("Customers: could not start: " + e)
  }
}
