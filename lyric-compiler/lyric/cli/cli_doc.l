package Lyric.Cli

import Std.Core
import Std.Collections
import Std.Console as Console
import Std.File as File
import Std.String as Str
import Std.Path as Path
import Std.Environment as Environment
import Lyric.Manifest as Mf
import Lyric.Doc as Doc
import Lyric.ContractMeta as Meta
import Lyric.Discovery as Disc

// ─────────────────────────────────────────────────────────────────────────────
// §8. Doc command
// ─────────────────────────────────────────────────────────────────────────────
func cmdDoc(argv: in slice[String]): Int {
  var explicitOut: Option[String] = None
  var manifestArg: Option[String] = None
  val positional: List[String] = newList()

  var i = 1
  while i < argv.length {
    val arg = argv[i]
    if arg == "-o" {
      if i + 1 < argv.length {
        explicitOut = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("doc: -o requires an argument")
        return 1
      }
    } else if arg == "--manifest" {
      if i + 1 < argv.length {
        manifestArg = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("doc: --manifest requires a path")
        return 1
      }
    } else {
      positional.add(arg)
      i += 1
    }
  }

  // Project-mode: no explicit source file — discover or use --manifest.
  // Writes <stem>.md for each source file into docs/ (or -o <dir>).
  if positional.count == 0 {
    val mfPath = match discoverManifest(manifestArg) {
      case Some(p) -> p
      case None -> {
        printErr("doc: missing source file and no lyric.toml found")
        return 1
      }
    }
    val (sourcePaths, hadFatal) = collectProjectSourcePaths(mfPath)
    if hadFatal {
      return 1
    }
    if sourcePaths.count == 0 {
      printErr("doc: no source files found in project")
      return 1
    }
    val mfDir = Path.dirname(mfPath)
    val outDir = match explicitOut { case Some(d) -> d; case None -> Path.join(mfDir, "docs") }
    match File.createDir(outDir) {
      case Ok(_) -> ()
      case Err(e) -> {
        printErr("doc: cannot create output directory '" + outDir + "': " + IOError.message(e))
        return 1
      }
    }
    var anyFailed = false
    var pi = 0
    while pi < sourcePaths.count {
      val sp = sourcePaths[pi]
      pi += 1
      val source = match File.readText(sp) {
        case Ok(t) -> t
        case Err(e) -> {
          printErr("doc: " + IOError.message(e))
          anyFailed = true
          continue
        }
      }
      val md = Doc.generate(source)
      // Preserve subdirectory structure so auth/main.l → docs/auth/main.md
      // rather than colliding with web/main.l → docs/main.md.
      val relLen = if Str.startsWith(sp, mfDir) { mfDir.length + 1 } else { 0 }
      val relPath = if relLen > 0 and relLen < sp.length {
        Str.substring(sp, relLen, sp.length - relLen)
      } else {
        Path.basename(sp)
      }
      val mdRel = stemOf(relPath, 2) + ".md"
      val outPath = Path.join(outDir, mdRel)
      val outParent = Path.dirname(outPath)
      var subdirOk = true
      if outParent != outDir {
        match File.createDir(outParent) {
          case Ok(_) -> ()
          case Err(e) -> {
            printErr("doc: cannot create output directory '" + outParent + "': " + IOError.message(e))
            anyFailed = true
            subdirOk = false
          }
        }
      }
      if subdirOk {
        match File.writeText(outPath, md) {
          case Ok(_) -> Console.println("wrote " + outPath)
          case Err(e) -> {
            printErr("doc: " + IOError.message(e))
            anyFailed = true
          }
        }
      }
    }
    if anyFailed {
      return 1
    }
    return 0
  }

  val sourcePath = positional[0]
  val source = match File.readText(sourcePath) {
    case Ok(text) -> text
    case Err(e) -> {
      printErr("doc: " + IOError.message(e))
      return 1
    }
  }

  val md = Doc.generate(source)
  match explicitOut {
    case None -> {
      Console.print(md)
      return 0
    }
    case Some(outPath) -> {
      val outDir = Path.dirname(outPath)
      match File.createDir(outDir) {
        case Ok(_) -> ()
        case Err(e) -> printErr("doc: warning: " + IOError.message(e))
      }
      match File.writeText(outPath, md) {
        case Ok(_) -> {
          Console.println("wrote " + outPath)
          return 0
        }
        case Err(e) -> {
          printErr("doc: " + IOError.message(e))
          return 1
        }
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §9. Public-api-diff command
// ─────────────────────────────────────────────────────────────────────────────
func cmdPublicApiDiff(argv: in slice[String]): Int {
  // Collect positional arguments (the two DLL paths).
  val positional: List[String] = newList()
  var i = 1
  while i < argv.length {
    positional.add(argv[i])
    i += 1
  }

  if positional.count != 2 {
    printErr("public-api-diff: expected `lyric public-api-diff <old.dll> <new.dll>`")
    return 1
  }

  val oldDll = positional[0]
  val newDll = positional[1]

  if not File.fileExists(oldDll) {
    printErr("public-api-diff: '" + oldDll + "' not found")
    return 1
  }
  if not File.fileExists(newDll) {
    printErr("public-api-diff: '" + newDll + "' not found")
    return 1
  }

  val oldJson = match Meta.readFromFile(oldDll) {
    case Some(j) -> j
    case None -> {
      printErr("public-api-diff: '" + oldDll + "' has no Lyric.Contract resource")
      return 1
    }
  }
  val newJson = match Meta.readFromFile(newDll) {
    case Some(j) -> j
    case None -> {
      printErr("public-api-diff: '" + newDll + "' has no Lyric.Contract resource")
      return 1
    }
  }

  val entries = Meta.diffContracts(oldJson, newJson)
  if entries.count == 0 {
    Console.println("No public-API changes between the two assemblies.")
    return 0
  }

  Console.println("Public-API diff: " + oldDll + " -> " + newDll)
  for e in entries.toArray() {
    Console.println(e)
  }

  if Meta.hasBreakingChanges(entries) {
    Console.println("")
    Console.println("SemVer: BREAKING — bump the major version.")
    return 2
  }

  Console.println("")
  Console.println("SemVer: backwards-compatible — bump the minor version.")
  0
}
