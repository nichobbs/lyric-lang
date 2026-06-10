package Lyric.Cli

import Std.Core
import Std.Collections
import Std.Console as Console
import Std.File as File
import Std.String as Str
import Std.Path as Path
import Std.Environment as Environment
import Lyric.Manifest as Mf
import Lyric.Fmt as Fmt
import Lyric.Discovery as Disc

// ─────────────────────────────────────────────────────────────────────────────
// §5. Fmt command
// ─────────────────────────────────────────────────────────────────────────────
func cmdFmt(argv: in slice[String]): Int {
  var checkMode = false
  var writeMode = false
  var stdinMode = false
  var manifestArg: Option[String] = None
  val positional: List[String] = newList()

  var i = 1
  while i < argv.length {
    val arg = argv[i]
    if arg == "--check" {
      checkMode = true
      i += 1
    } else if arg == "--write" {
      writeMode = true
      i += 1
    } else if arg == "--stdin" {
      stdinMode = true
      i += 1
    } else if arg == "--manifest" {
      if i + 1 < argv.length {
        manifestArg = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("fmt: --manifest requires a path")
        return 1
      }
    } else {
      positional.add(arg)
      i += 1
    }
  }

  // --stdin: read all of stdin, format, write to stdout.
  if stdinMode {
    if writeMode {
      printErr("fmt: --stdin and --write are mutually exclusive — --write has no effect on stdin")
      return 1
    }
    val stdinLines: List[String] = newList()
    var reading = true
    while reading {
      match Console.readLine() {
        case Err(_) -> {
          reading = false
        }
        case Ok(line) -> {
          stdinLines.add(line)
        }
      }
    }
    val source = if stdinLines.count > 0 { Str.joinList("\n", stdinLines) + "\n" } else { "" }
    if checkMode {
      if Fmt.isFormattedSource(source) {
        return 0
      } else {
        printErr("fmt: stdin: not formatted")
        return 1
      }
    }
    val checkResult = Fmt.formatSourceChecked(source)
    if not Fmt.fmtCheckIsOk(checkResult) {
      printErr("fmt: stdin: " + Fmt.fmtCheckMessage(checkResult))
      return 1
    }
    Console.print(Fmt.fmtCheckText(checkResult))
    return 0
  }

  // Project-mode: no explicit source file — discover or use --manifest.
  // Project-mode: default is dry-run (lists what would change); --write applies changes; --check gates CI.
  if positional.count == 0 {
    val mfPath = match discoverManifest(manifestArg) {
      case Some(p) -> p
      case None -> {
        printErr("fmt: missing source file and no lyric.toml found")
        printUsage()
        return 1
      }
    }
    val (sourcePaths, hadFatal) = collectProjectSourcePaths(mfPath)
    if hadFatal {
      return 1
    }
    if sourcePaths.count == 0 {
      printErr("fmt: no source files found in project")
      return 1
    }
    if checkMode {
      // --check: silently exit 1 if any file needs formatting; print which ones.
      var anyUnformatted = false
      var pi = 0
      while pi < sourcePaths.count {
        val sp = sourcePaths[pi]
        pi += 1
        val source = match File.readText(sp) {
          case Ok(t) -> t
          case Err(e) -> {
            printErr("fmt: " + IOError.message(e))
            anyUnformatted = true
            continue
          }
        }
        if not Fmt.isFormattedSource(source) {
          printErr(sp + ": not formatted — run `lyric fmt --write` to reformat")
          anyUnformatted = true
        }
      }
      if anyUnformatted {
        return 1
      }
      return 0
    }
    if writeMode {
      // --write: format every file in-place; skip files that are already correct.
      var anyFailed = false
      var fi = 0
      while fi < sourcePaths.count {
        val sp = sourcePaths[fi]
        fi += 1
        val source = match File.readText(sp) {
          case Ok(t) -> t
          case Err(e) -> {
            printErr("fmt: " + IOError.message(e))
            anyFailed = true
            continue
          }
        }
        val checkResult = Fmt.formatSourceChecked(source)
        if not Fmt.fmtCheckIsOk(checkResult) {
          printErr(sp + ": " + Fmt.fmtCheckMessage(checkResult))
          anyFailed = true
          continue
        }
        val formatted = Fmt.fmtCheckText(checkResult)
        if formatted == source {
          continue
        }
        match File.writeText(sp, formatted) {
          case Ok(_) -> Console.println("formatted " + sp)
          case Err(e) -> {
            printErr("fmt: " + IOError.message(e))
            anyFailed = true
          }
        }
      }
      if anyFailed {
        return 1
      }
      return 0
    }
    // Default (no --write, no --check): dry-run — report what would change without writing.
    var anyUnformatted = false
    var di = 0
    while di < sourcePaths.count {
      val sp = sourcePaths[di]
      di += 1
      val source = match File.readText(sp) {
        case Ok(t) -> t
        case Err(e) -> {
          printErr("fmt: " + IOError.message(e))
          anyUnformatted = true
          continue
        }
      }
      if not Fmt.isFormattedSource(source) {
        Console.println(sp + ": would reformat")
        anyUnformatted = true
      }
    }
    if anyUnformatted {
      Console.println("run `lyric fmt --write` to apply")
      return 1
    }
    return 0
  }

  // Multi-file mode: apply formatting to each positional argument.
  var anyFailed = false
  var fi = 0
  while fi < positional.count {
    val sourcePath = positional[fi]
    fi += 1
    val source = match File.readText(sourcePath) {
      case Ok(text) -> text
      case Err(e) -> {
        printErr("fmt: " + IOError.message(e))
        anyFailed = true
        continue
      }
    }

    // `--check` is a read-only "is this already formatted?" probe: it must
    // never abort on a file the formatter cannot round-trip (it writes
    // nothing), so it stays on the plain `isFormattedSource` comparison.
    if checkMode {
      if not Fmt.isFormattedSource(source) {
        printErr(sourcePath + ": not formatted — run `lyric fmt --write`")
        anyFailed = true
      }
      continue
    }

    // Write / print: route through the loss-checked path so we never emit
    // or persist output that would drop a comment, change the code-token
    // sequence, or fail to re-parse.  See `Lyric.Fmt.formatSourceChecked`.
    val checkResult = Fmt.formatSourceChecked(source)
    if not Fmt.fmtCheckIsOk(checkResult) {
      printErr(sourcePath + ": " + Fmt.fmtCheckMessage(checkResult))
      anyFailed = true
      continue
    }
    val formatted = Fmt.fmtCheckText(checkResult)

    if writeMode {
      match File.writeText(sourcePath, formatted) {
        case Ok(_) -> Console.println("formatted " + sourcePath)
        case Err(e) -> {
          printErr("fmt: " + IOError.message(e))
          anyFailed = true
        }
      }
      continue
    }

    Console.print(formatted)
  }

  if anyFailed {
    1
  } else {
    0
  }
}
