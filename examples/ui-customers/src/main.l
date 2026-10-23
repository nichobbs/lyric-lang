//! Customers — composition root: binds the repository, maps URLs to screens
//! and starts the server-driven web host, or with `--desktop` the desktop
//! host (docs/65 §10.2), which shows the same screens in a window.
//!
//! Layer: app.  The only package that sees every layer.
//!
//! Run:  lyric run --manifest examples/ui-customers/lyric.toml
//! Open: http://localhost:8080/customers
//! Set LYRIC_UI_PORT to listen on another port (the browser e2e does).
//! Or:   lyric run --manifest examples/ui-customers/lyric.toml -- --desktop
//!       (needs libwebview, see scripts/ci/install-webview.sh)
@runtime_checked
package Customers

import Std.Core
import Std.Console
import Std.Environment as Env
import Std.Parse as Parse
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
  val base = WebHost.defaultConfig("Customers")
  val portText = Env.getVarOrDefault("LYRIC_UI_PORT", "")
  val cfg = if portText == "" {
    base
  } else {
    match Parse.tryParseInt(portText) {
      case Ok(p) -> base.copy(port = p)
      case Err(_) -> {
        Console.error("Customers: LYRIC_UI_PORT is not an integer: " + portText)
        base
      }
    }
  }
  println("Customers: http://localhost:" + cfg.port.toString() + "/customers")
  match WebHost.serve(cfg, { url: String -> route(repo, url) }) {
    case Ok(_) -> ()
    case Err(e) -> Console.error("Customers: could not start: " + e)
  }
}
