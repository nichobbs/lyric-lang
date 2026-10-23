//! Reads a plugin artifact's `plugin.json` with the `Std.Plugin` runtime's own
//! parser (`readPluginManifest`), so scripts/ci/plugin-sdk-e2e.sh checks that
//! what `lyric plugin pack` writes is what a host loads.  Prints
//! `<id> <version> <payload count>` and exits 0, or prints the issue and
//! exits 1.
//!
//!   lyric run scripts/ci/plugin-sdk/read_manifest.l -- <artifact dir>
package PluginSdkE2e.ReadManifest

import Std.Core
import Std.Collections
import Std.Console as Console
import Std.Environment as Environment
import Std.Plugin

func main(): Int {
  val args = Environment.args()
  if args.length == 0 {
    Console.error("usage: read_manifest <artifact dir>")
    return 2
  }
  match readPluginManifest(args[args.length - 1]) {
    case Ok(m) -> {
      Console.println(m.id + " " + m.version + " " + m.payloads.count.toString())
      0
    }
    case Err(issue) -> {
      Console.error("Std.Plugin rejected the manifest: " + issue.message)
      1
    }
  }
}
