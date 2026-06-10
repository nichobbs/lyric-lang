package Lyric.Cli

import Std.Core
import Std.Collections
import Std.Console as Console
import Std.File as File
import Std.String as Str
import Std.Path as Path
import Std.Environment as Environment
import Lyric.Manifest as Mf
import Lyric.Lexer
import Lyric.Lint as Lint
import Lyric.Discovery as Disc

// ─────────────────────────────────────────────────────────────────────────────
// §6. Lint command
// ─────────────────────────────────────────────────────────────────────────────
func cmdLint(argv: in slice[String]): Int {
  var errorOnWarning = false
  var manifestArg: Option[String] = None
  val positional: List[String] = newList()

  var i = 1
  while i < argv.length {
    val arg = argv[i]
    if arg == "--error-on-warning" {
      errorOnWarning = true
      i += 1
    } else if arg == "--manifest" {
      if i + 1 < argv.length {
        manifestArg = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("lint: --manifest requires a path")
        return 2
      }
    } else {
      positional.add(arg)
      i += 1
    }
  }

  // Project-mode: no explicit source file — discover or use --manifest.
  if positional.count == 0 {
    val mfPath = match discoverManifest(manifestArg) {
      case Some(p) -> p
      case None -> {
        printErr("lint: missing source file and no lyric.toml found")
        printUsage()
        return 2
      }
    }
    val (sourcePaths, hadFatal) = collectProjectSourcePaths(mfPath)
    if hadFatal {
      return 2
    }
    if sourcePaths.count == 0 {
      printErr("lint: no source files found in project")
      return 2
    }
    var hasError = false
    var hasWarning = false
    var pi = 0
    while pi < sourcePaths.count {
      val sp = sourcePaths[pi]
      pi += 1
      val source = match File.readText(sp) {
        case Ok(t) -> t
        case Err(e) -> {
          printErr("lint: " + IOError.message(e))
          hasError = true
          continue
        }
      }
      val lintDiags = Lint.lint(source)
      for d in lintDiags.toArray() {
        val sev = match d.severity { case LintError -> "error"; case LintWarning -> "warning" }
        printErr(
          sp + ": " + d.code + " " + sev + " [" + toString(d.span.startPos.line) + ":" + toString(d.span.startPos.column) +
            "]: " +
            d.message
        )
        match d.severity {
          case LintError -> {
            hasError = true
          }
          case LintWarning -> {
            hasWarning = true
          }
        }
      }
    }
    if hasError or (errorOnWarning and hasWarning) {
      return 1
    }
    return 0
  }

  // Single-file mode (existing behaviour):
  val sourcePath = positional[0]
  val source = match File.readText(sourcePath) {
    case Ok(text) -> text
    case Err(e) -> {
      printErr("lint: " + IOError.message(e))
      return 2
    }
  }

  val lintDiags = Lint.lint(source)
  var hasError = false
  var hasWarning = false
  for d in lintDiags.toArray() {
    val sev = match d.severity { case LintError -> "error"; case LintWarning -> "warning" }
    printErr(
      d.code + " " + sev + " [" + toString(d.span.startPos.line) + ":" + toString(d.span.startPos.column) + "]: " +
        d.message
    )
    match d.severity {
      case LintError -> {
        hasError = true
      }
      case LintWarning -> {
        hasWarning = true
      }
    }
  }

  if hasError or (errorOnWarning and hasWarning) {
    1
  } else {
    0
  }
}
