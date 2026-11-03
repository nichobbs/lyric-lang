package Lyric.Cli

import Std.Core
import Std.Collections
import Std.Errors
import Std.Console as Console
import Std.File as File
import Lyric.Iface

// ─────────────────────────────────────────────────────────────────────────────
// `lyric interface dump <file.lyri>` (docs/70 §9.6)
// ─────────────────────────────────────────────────────────────────────────────
// Prints a package interface as text: the canonical dump, then the interface
// hash.  Exit 0 on success, 1 for a usage error or an unreadable or malformed
// interface.
func cmdInterface(argv: in slice[String]): Int {
  if argv.length < 2 or argv[1] != "dump" {
    printErr("usage: lyric interface dump <file.lyri>")
    return 1
  }
  if argv.length != 3 {
    printErr("usage: lyric interface dump <file.lyri>")
    return 1
  }
  val path = argv[2]
  match File.readBytes(path) {
    case Err(e) -> {
      printErr("interface dump: cannot read " + path + ": " + e.message())
      1
    }
    case Ok(bytes) -> match decodeIface(bytes) {
      case Err(msg) -> {
        printErr("interface dump: " + path + ": " + msg)
        1
      }
      case Ok(iface) -> {
        Console.print(dumpIface(iface))
        Console.println("hash: " + ifaceHash(bytes))
        0
      }
    }
  }
}
