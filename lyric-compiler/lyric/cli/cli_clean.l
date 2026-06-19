package Lyric.Cli

import Std.Core
import Std.Collections
import Std.Console as Console
import Std.File as File
import Std.Path as Path
import Lyric.Discovery as Disc

// ─────────────────────────────────────────────────────────────────────────────
// §11e. Clean command
// ─────────────────────────────────────────────────────────────────────────────
func cmdClean(argv: in slice[String]): Int {
  var manifestArg: Option[String] = None
  val positional: List[String] = newList()

  var i = 1
  while i < argv.length {
    val arg = argv[i]
    if arg == "--manifest" {
      if i + 1 < argv.length {
        manifestArg = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("clean: --manifest requires a path")
        return 1
      }
    } else {
      positional.add(arg)
      i += 1
    }
  }

  val rootDir = if positional.count > 0 {
    positional[0]
  } else {
    match discoverManifest(manifestArg) {
      case Some(p) -> Path.dirname(p)
      case None -> "."
    }
  }

  val toRemove: List[String] = newList()
  toRemove.add(Path.join(rootDir, "bin"))
  toRemove.add(Path.join(rootDir, ".lyric-run"))
  toRemove.add(Path.join(rootDir, ".lyric-test"))
  toRemove.add(Path.join(rootDir, ".lyric-bench"))
  toRemove.add(Path.join(rootDir, ".lyric-check"))
  toRemove.add(Path.join(rootDir, ".lyric-release"))

  var anyRemoved = false
  var anyFailed = false
  var ri = 0
  while ri < toRemove.count {
    val dir = toRemove[ri]
    ri += 1
    if File.dirExists(dir) {
      match File.deleteDirRecursive(dir) {
        case Ok(_) -> {
          Console.println("clean: removed " + dir)
          anyRemoved = true
        }
        case Err(e) -> {
          printErr("clean: could not remove " + dir + ": " + IOError.message(e))
          anyFailed = true
        }
      }
    }
  }

  if not anyRemoved and not anyFailed {
    Console.println("clean: nothing to remove")
  }
  if anyFailed {
    1
  } else {
    0
  }
}
