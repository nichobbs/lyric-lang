package Lyric.Cli

import Std.Core
import Std.Collections
import Std.Errors
import Std.Console as Console
import Std.File as File
import Std.String as Str
import Msil.MetadataReader as Mdr
import Lyric.Iface
import Lyric.Symbols

// ─────────────────────────────────────────────────────────────────────────────
// `lyric interface dump <file.lyri|assembly.dll>` (docs/70 §9.6)
// ─────────────────────────────────────────────────────────────────────────────
// Prints each package interface in the file as text: the canonical dump, then
// the interface hash.  A `.lyri` file holds one interface; a .NET assembly
// holds one `Lyric.Interface.<Pkg>` resource per package.  Exit 0 on success,
// 1 for a usage error or an unreadable, malformed or absent interface.
record FoundIface {
  label: String
  bytes: slice[Byte]
}

func interfaceUsage(): Int {
  printErr("usage: lyric interface dump <file.lyri|assembly.dll>")
  1
}

// The interfaces `path` holds, as (label, bytes).  `None` after reporting why
// there are none.
func interfacesOf(path: in String): Option[List[FoundIface]] {
  val res: List[FoundIface] = newList()
  if Str.endsWith(path, ".dll") {
    match Mdr.openResourceImage(path) {
      case None -> {
        printErr("interface dump: " + path + ": not a readable .NET assembly")
        return None
      }
      case Some(ri) -> {
        val prefix = "Lyric.Interface."
        for name in Mdr.resourceNamesIn(ri) {
          if Str.startsWith(name, prefix) {
            match Mdr.tryReadResourceIn(ri, name) {
              case Some(bytes) -> res.add(
                FoundIface(label = name.substring(prefix.length, name.length - prefix.length), bytes = bytes)
              )
              case None -> {
                printErr("interface dump: " + path + ": the resource " + name + " cannot be read")
                return None
              }
            }
          }
        }
        if res.count == 0 {
          printErr("interface dump: " + path + ": the assembly carries no Lyric.Interface.* resource")
          return None
        }
      }
    }
  } else if Str.endsWith(path, ".lyri") {
    match File.readBytes(path) {
      case Err(e) -> {
        printErr("interface dump: cannot read " + path + ": " + e.message())
        return None
      }
      case Ok(bytes) -> res.add(FoundIface(label = "", bytes = bytes))
    }
  } else {
    printErr("interface dump: " + path + ": expected a .lyri or .dll file")
    return None
  }
  Some(value = res)
}

func cmdInterface(argv: in slice[String]): Int {
  if argv.length != 3 or argv[1] != "dump" {
    return interfaceUsage()
  }
  val path = argv[2]
  match interfacesOf(path) {
    case None -> 1
    case Some(found) -> {
      var status = 0
      var first = true
      for entry in found {
        val label = entry.label
        val bytes = entry.bytes
        val interner = newDefPathInterner()
        match decodeIface(bytes, interner) {
          case Err(msg) -> {
            printErr("interface dump: " + path + (if label.length > 0 then " (" + label + ")" else "") + ": " + msg)
            status = 1
          }
          case Ok(iface) -> {
            if not first {
              Console.println("")
            }
            first = false
            Console.print(dumpIface(iface, interner))
            Console.println("hash: " + ifaceHash(bytes))
          }
        }
      }
      status
    }
  }
}
