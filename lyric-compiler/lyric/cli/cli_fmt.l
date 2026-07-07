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

// Returns true when any op in the CONTEXT-window around `pos` is a change (not equal).
func isInHunk(pos: in Int, tags: in List[Int], opCnt: in Int, context: in Int): Bool {
  val lo = if pos >= context { pos - context } else { 0 }
  val hi = if pos + context < opCnt { pos + context } else { opCnt - 1 }
  var k = lo
  while k <= hi {
    if tags[k] != 0 {
      return true
    }
    k += 1
  }
  false
}

// Compute a unified diff between `aText` and `bText` (line-based LCS).
// Returns "" when the texts are identical.  `aPath` appears in --- / +++ headers.
// O(n*m) time and space in the number of lines: acceptable for typical source
// files (hundreds of lines), but may be slow for very large generated files.
func diffLinesUnified(aPath: in String, aText: in String, bText: in String): String {
  if aText == bText {
    return ""
  }
  val aLines = Str.split(aText, "\n")
  val bLines = Str.split(bText, "\n")
  val n = aLines.length
  val m = bLines.length

  // LCS DP table: flat (n+1)*(m+1) list built row-major via List.add() only.
  val dp: List[Int] = newList()
  var j0 = 0
  while j0 <= m {
    dp.add(0)
    j0 += 1
  }
  var dpI = 1
  while dpI <= n {
    dp.add(0)
    var dpJ = 1
    while dpJ <= m {
      val diag = dp[(dpI - 1) * (m + 1) + (dpJ - 1)]
      val up = dp[(dpI - 1) * (m + 1) + dpJ]
      val left = dp[dpI * (m + 1) + (dpJ - 1)]
      if aLines[dpI - 1] == bLines[dpJ - 1] {
        dp.add(diag + 1)
      } else {
        dp.add(if up >= left { up } else { left })
      }
      dpJ += 1
    }
    dpI += 1
  }

  // Backtrack to produce edit ops (built in reverse, then reversed).
  // Tags: 0=equal, 1=delete(from a), 2=insert(into b)
  val revTags: List[Int] = newList()
  val revText: List[String] = newList()
  var bi = n
  var bj = m
  while bi > 0 or bj > 0 {
    if bi > 0 and bj > 0 and aLines[bi - 1] == bLines[bj - 1] {
      revTags.add(0)
      revText.add(aLines[bi - 1])
      bi -= 1
      bj -= 1
    } else if bj > 0 and (bi == 0 or dp[bi * (m + 1) + (bj - 1)] >= dp[(bi - 1) * (m + 1) + bj]) {
      revTags.add(2)
      revText.add(bLines[bj - 1])
      bj -= 1
    } else {
      revTags.add(1)
      revText.add(aLines[bi - 1])
      bi -= 1
    }
  }

  val opCnt = revTags.count
  val tags: List[Int] = newList()
  val opLines: List[String] = newList()
  var ri = opCnt - 1
  while ri >= 0 {
    tags.add(revTags[ri])
    opLines.add(revText[ri])
    ri -= 1
  }

  val CONTEXT = 3

  // Build line-number maps
  val aNum: List[Int] = newList()
  val bNum: List[Int] = newList()
  var aN = 1
  var bN = 1
  var ki = 0
  while ki < opCnt {
    aNum.add(aN)
    bNum.add(bN)
    if tags[ki] != 2 {
      aN += 1
    }
    if tags[ki] != 1 {
      bN += 1
    }
    ki += 1
  }

  // Build inHunk indicator
  val inHunk: List[Int] = newList()
  var hp = 0
  while hp < opCnt {
    inHunk.add(if isInHunk(hp, tags, opCnt, CONTEXT) { 1 } else { 0 })
    hp += 1
  }

  // Format hunks
  val lines: List[String] = newList()
  lines.add("--- a/" + aPath)
  lines.add("+++ b/" + aPath)

  var pos = 0
  while pos < opCnt {
    if inHunk[pos] == 0 {
      pos += 1
      continue
    }
    val hunkStart = pos
    var he = pos
    while he < opCnt and inHunk[he] == 1 {
      he += 1
    }
    val hunkEnd = he - 1

    var aCnt = 0
    var bCnt = 0
    var hk = hunkStart
    while hk <= hunkEnd {
      if tags[hk] != 2 {
        aCnt += 1
      }
      if tags[hk] != 1 {
        bCnt += 1
      }
      hk += 1
    }

    lines.add(
      "@@ -" + toString(aNum[hunkStart]) + "," + toString(aCnt) + " +" + toString(bNum[hunkStart]) + "," + toString(bCnt) +
        " @@"
    )

    hk = hunkStart
    while hk <= hunkEnd {
      if tags[hk] == 0 {
        lines.add(" " + opLines[hk])
      } else if tags[hk] == 1 {
        lines.add("-" + opLines[hk])
      } else {
        lines.add("+" + opLines[hk])
      }
      hk += 1
    }

    pos = he
  }

  Str.joinList("\n", lines) + "\n"
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. Fmt command
// ─────────────────────────────────────────────────────────────────────────────
func cmdFmt(argv: in slice[String]): Int {
  var checkMode = false
  var writeMode = false
  var stdinMode = false
  var diffMode = false
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
    } else if arg == "--diff" {
      diffMode = true
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
    val sourcePaths = match resolveProjectSources(manifestArg) {
      case ProjSourcesMissingManifest -> {
        printErr("fmt: missing source file and no lyric.toml found")
        printUsage()
        return 1
      }
      case ProjSourcesFatal -> return 1
      case ProjSourcesFound(_, paths) -> paths
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
        if diffMode {
          val dryRes = Fmt.formatSourceChecked(source)
          if Fmt.fmtCheckIsOk(dryRes) {
            val diff = diffLinesUnified(sp, source, Fmt.fmtCheckText(dryRes))
            if diff != "" {
              Console.print(diff)
            }
          } else {
            Console.println(sp + ": would reformat")
          }
        } else {
          Console.println(sp + ": would reformat")
        }
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
      if diffMode {
        val diff = diffLinesUnified(sourcePath, source, formatted)
        if diff != "" {
          Console.print(diff)
        }
      }
      if formatted != source {
        match File.writeText(sourcePath, formatted) {
          case Ok(_) -> if not diffMode { Console.println("formatted " + sourcePath) }
          case Err(e) -> {
            printErr("fmt: " + IOError.message(e))
            anyFailed = true
          }
        }
      }
      continue
    }

    if diffMode {
      val diff = diffLinesUnified(sourcePath, source, formatted)
      if diff != "" {
        Console.print(diff)
        anyFailed = true
      }
    } else {
      Console.print(formatted)
    }
  }

  if anyFailed {
    1
  } else {
    0
  }
}
