//! Review — serves the review screen on the server-driven web host
//! (docs/65 §10.1), with its widgets from the plugins in a directory.
//!
//! Layer: app.
//!
//!   lyric plugin pack --manifest examples/plugins/ui-widgets/widgets/lyric.toml --targets dotnet \
//!     --sign-key examples/plugins/keys/example-publisher.key -o plugins
//!   lyric run --manifest examples/plugins/ui-widgets/review/lyric.toml -- plugins
//!   then open http://localhost:8080/review
@runtime_checked
package Review

import Std.Core
import Std.Console
import Std.Environment as Env
import Ui.Host.Web as WebHost
import Review.App.{loadWidgets, route}

func main(): Unit {
  // `args()` follows the host's convention on argv0, so the directory is
  // the last argument.
  val argv = Env.args()
  val dir = if argv.length == 0 then "plugins" else argv[argv.length - 1]
  val runner = loadWidgets(dir)
  val cfg = WebHost.defaultConfig("Review")
  println("Review: http://localhost:" + cfg.port.toString() + "/review")
  match WebHost.serve(cfg, { url: String -> route(runner, url) }) {
    case Ok(_) -> ()
    case Err(e) -> Console.error("Review: could not start: " + e)
  }
}
