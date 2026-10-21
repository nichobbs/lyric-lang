//! Customers — composition root: binds the repository, maps URLs to screens
//! and starts the server-driven web host, or with `--desktop` the desktop
//! host (docs/65 §10.2), which shows the same screens in a window.
//!
//! Layer: app.  The only package that sees every layer.
//!
//! Run:  lyric run --manifest examples/ui-customers/lyric.toml
//! Open: http://localhost:8080/customers
//! Or:   lyric run --manifest examples/ui-customers/lyric.toml -- --desktop
//!       (needs libwebview, see scripts/ci/install-webview.sh)
@runtime_checked
package Customers

import Std.Core
import Std.Console
import Std.Environment as Env
import Ui.Host.Web as WebHost
import Ui.Host.Desktop as Desktop
import Customers.Store
import Customers.App.{route}

func main(): Unit {
  val repo = Store.seeded()
  for arg in Env.args() {
    if arg == "--desktop" {
      val desk = Desktop.defaultConfig("Customers").copy(startPath = "/customers")
      Desktop.run(desk, { url: String -> route(repo, url) })
    }
  }
  val cfg = WebHost.defaultConfig("Customers")
  println("Customers: http://localhost:" + cfg.port.toString() + "/customers")
  match WebHost.serve(cfg, { url: String -> route(repo, url) }) {
    case Ok(_) -> ()
    case Err(e) -> Console.error("Customers: could not start: " + e)
  }
}
