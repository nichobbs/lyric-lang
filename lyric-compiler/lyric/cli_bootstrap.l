package Lyric.CliBootstrap

import Std.Core
import Std.Collections
import Std.Console as Console
import Std.Environment as Environment
import Lyric.Discovery as Disc
import Lyric.Cli.Shared
import Lyric.Cli.Build

// Minimal bootstrap entry point.  It exposes only the commands needed to
// self-host the compiler — `build` and the internal per-package emit — so its
// emitted assembly imports just the Build closure and stays well under the
// 64 KB string-heap limit.  The legacy stage-0 binary mis-emits assemblies
// whose string heap exceeds 64 KB; the full dispatcher (Lyric.Cli, every
// subcommand) is over that limit, so bootstrap stage 1 builds THIS entry
// first, then uses the resulting heap-correct compiler to re-emit the full
// Lyric.Cli closure.  Not shipped: the AOT binary always trampolines into the
// full Lyric.Cli.Program.main.
pub func main(argv: in slice[String]): Int {
  if argv.length == 0 {
    match Disc.findNearestManifest(Environment.currentDirectory()) {
      case Some(p) -> {
        val buildArgv: List[String] = newList()
        buildArgv.add("build")
        buildArgv.add("--manifest")
        buildArgv.add(p)
        return cmdBuild(buildArgv.toArray())
      }
      case None -> {
        printErr("bootstrap lyric: no project found and no command given")
        return 1
      }
    }
  }
  val cmd = argv[0]
  if cmd == "--internal-perpackage-build" {
    return cmdInternalPerpackage(argv)
  }
  if cmd == "build" {
    return cmdBuild(argv)
  }
  if cmd == "--version" or cmd == "-v" {
    Console.println("lyric " + VERSION())
    return 0
  }
  printErr("bootstrap lyric: unsupported command '" + cmd + "' (minimal bootstrap build)")
  1
}
