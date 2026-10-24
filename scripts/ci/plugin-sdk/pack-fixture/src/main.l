//! A hand-written plugin entry point for `lyric plugin pack`'s end-to-end test
//! (scripts/ci/plugin-sdk-e2e.sh).  Run with `--lyric-plugin-manifest` it
//! prints a fixed manifest and exits 0, as a plugin's generated `main` does
//! (D207 Decision 3).  The manifest's numbers include one above 2^53 so the test
//! sees pack keep the plugin's text exactly.
package PackFixture

import Std.Core
import Std.Console as Console
import Std.Environment as Environment

val manifestJson: String = "{\"schema\":1,\"id\":\"demo.pack-fixture\",\"version\":\"0.3.0\",\"publisher\":\"lyric-e2e\",\"points\":[{\"point\":\"Demo.Api.Greeter\",\"version\":\"1.2\",\"contributions\":{\"commands\":[\"greet\"],\"priority\":9007199254740993}}],\"capabilities\":{\"required\":[{\"name\":\"Demo.Api.Files\",\"grant\":{\"roots\":[\"\${workspace}\"]}}],\"optional\":[{\"name\":\"Demo.Api.Notify\",\"grant\":null}]}}"

func main(): Int {
  // The host convention decides whether argv0 is the first entry, so the
  // flag is looked for as the last argument.
  val args = Environment.args()
  if args.length > 0 and args[args.length - 1] == "--lyric-plugin-manifest" {
    Console.println(manifestJson)
    return 0
  }
  Console.error("this fixture only answers --lyric-plugin-manifest")
  1
}
