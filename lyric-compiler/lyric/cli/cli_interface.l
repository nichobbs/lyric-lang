package Lyric.Cli

import Std.Core
import Std.Collections
import Std.Errors
import Std.Console as Console
import Std.File as File
import Std.String as Str
import Std.Zip as Zip
import Msil.MetadataReader as Mdr
import Lyric.Iface
import Lyric.Symbols

// ─────────────────────────────────────────────────────────────────────────────
// `lyric interface dump <file.lyri|assembly.dll|library.jar>` (docs/70 §9.6)
// ─────────────────────────────────────────────────────────────────────────────
// Prints each package interface in the file as text: the canonical dump, then
// the interface hash.  A `.lyri` file holds one interface; a .NET assembly
// holds one `Lyric.Interface.<Pkg>` resource per package; a JAR holds one
// `META-INF/lyric/<Pkg>.lyri` entry per package.  Exit 0 on success,
// 1 for a usage error or an unreadable, malformed or absent interface.
record FoundIface {
  label: String
  bytes: slice[Byte]
}

func interfaceUsage(): Int {
  printErr("usage: lyric interface dump <file.lyri|assembly.dll|library.jar>")
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
  } else if Str.endsWith(path, ".jar") {
    match File.readBytes(path) {
      case Err(e) -> {
        printErr("interface dump: cannot read " + path + ": " + e.message())
        return None
      }
      case Ok(jar) -> {
        val limits = Zip.ZipLimits(
          maxEntries = 65535,
          maxEntrySize = 536870912i64,
          maxTotalSize = 4294967296i64,
          maxRatio = 1000i64
        )
        match Zip.readZipDirectory(jar, limits) {
          case Err(_) -> {
            printErr("interface dump: " + path + ": not a readable JAR")
            return None
          }
          case Ok(entries) -> {
            val prefix = "META-INF/lyric/"
            for e in entries {
              if Str.startsWith(e.name, prefix) and Str.endsWith(e.name, ".lyri") {
                match Zip.readZipEntry(jar, e) {
                  case Ok(bytes) -> res.add(
                    FoundIface(
                      label = e.name.substring(prefix.length, e.name.length - prefix.length - 5),
                      bytes = bytes
                    )
                  )
                  case Err(_) -> {
                    printErr("interface dump: " + path + ": the entry " + e.name + " cannot be read")
                    return None
                  }
                }
              }
            }
            if res.count == 0 {
              printErr("interface dump: " + path + ": the JAR carries no META-INF/lyric/*.lyri entry")
              return None
            }
          }
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
    printErr("interface dump: " + path + ": expected a .lyri, .dll or .jar file")
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
