package Lyric.Cli

import Std.Core
import Std.Collections
import Std.Console as Console
import Std.File as File
import Std.String as Str
import Std.Path as Path
import Std.Parse as Parse
import Std.Environment as Environment
import Std.Errors
import Lyric.Manifest as Mf
import Lyric.Workspace as Ws
import Lyric.Discovery as Disc

// ─────────────────────────────────────────────────────────────────────────────
// §14. lyric version — print and update package versions
// ─────────────────────────────────────────────────────────────────────────────

// Return true when `s` is a non-negative decimal integer with no leading zeros
// (or "0" itself).
func isNonNegativeInt(s: in String): Bool {
  if s.length == 0 {
    return false
  }
  // Reject leading zeros ("007", "01") — invalid per semver spec.
  if s.length > 1 and s.startsWith("0") {
    return false
  }
  match Parse.parseOptInt(s) {
    case None -> false
    case Some(n) -> n >= 0
  }
}

// Return "" if `v` looks like a valid semver (MAJOR.MINOR.PATCH[+-suffix])
// where MAJOR, MINOR, and PATCH are non-negative integers, or a human-readable
// diagnostic string if not.
pub func validateSemver(v: in String): String {
  if v.length == 0 {
    return "version cannot be empty"
  }
  val first = v.indexOf(".")
  if first <= 0 {
    return "invalid semver '" + v + "': expected MAJOR.MINOR.PATCH"
  }
  val suffix = v.substring(first + 1)
  val relSecond = suffix.indexOf(".")
  if relSecond < 0 {
    return "invalid semver '" + v + "': expected MAJOR.MINOR.PATCH"
  }
  val second = first + 1 + relSecond
  if second <= first + 1 {
    return "invalid semver '" + v + "': expected MAJOR.MINOR.PATCH"
  }
  val major = v.substring(0, first)
  val minor = v.substring(first + 1, second - first - 1)
  // PATCH ends at the first '+' or '-' (pre-release / build metadata) or EOL.
  val patchStart = second + 1
  val patchRaw = v.substring(patchStart, v.length - patchStart)
  val plusPos = patchRaw.indexOf("+")
  val dashPos = patchRaw.indexOf("-")
  val patch = if plusPos >= 0 and (dashPos < 0 or plusPos < dashPos) {
    patchRaw.substring(0, plusPos)
  } else if dashPos >= 0 {
    patchRaw.substring(0, dashPos)
  } else {
    patchRaw
  }
  if not isNonNegativeInt(major) {
    return "invalid semver '" + v + "': MAJOR must be a non-negative integer"
  }
  if not isNonNegativeInt(minor) {
    return "invalid semver '" + v + "': MINOR must be a non-negative integer"
  }
  if not isNonNegativeInt(patch) {
    return "invalid semver '" + v + "': PATCH must be a non-negative integer"
  }
  ""
}

// Return the index of the line inside `lines` whose trimmed left-of-`=`
// token equals "version" (a TOML key definition — tolerant of any TOML-valid
// spacing around `=`, e.g. `version="1.0.0"` or `version  =  "1.0.0"`), or
// -1 if none is found.  Comment lines and table headers never match.
func indexOfVersionLine(lines: in slice[String]): Int {
  var i = 0
  while i < lines.length {
    val t = Str.trim(lines[i])
    if not Str.startsWith(t, "#") and not Str.startsWith(t, "[") {
      val eq = t.indexOf("=")
      if eq > 0 and Str.trim(t.substring(0, eq)) == "version" {
        return i
      }
    }
    i += 1
  }
  -1
}

// Replace `version = "<oldVersion>"` with `version = "<newVersion>"` inside
// the [package] section of a lyric.toml text.  The [package] section boundary
// is determined by the next section header (`\n[`), or end-of-file.  Tolerant
// of any TOML-valid spacing around `=` (`version="x"`, `version  =  "x"`, the
// canonical `version = "x"`) since all are valid TOML that `Mf.parseManifest`
// accepts — locates the value's exact quote offsets on the matched line
// rather than matching a fixed-spacing literal, so indentation and any
// trailing inline comment on that line are preserved untouched.
// Returns the updated text or an error string.
pub func replaceVersionInToml(
  text: in String,
  oldVersion: in String,
  newVersion: in String,
): Result[String, String] {
  val pkgHeader = "[package]"
  val pkgStart = text.indexOf(pkgHeader)
  if pkgStart < 0 {
    return Err("[package] section not found in lyric.toml")
  }
  val afterHeader = pkgStart + pkgHeader.length

  // End of the [package] section: first "\n[" after the header, or EOF.
  val nextSection = text.indexOf("\n[", afterHeader)
  val sectionLen = if nextSection < 0 {
    text.length - afterHeader
  } else {
    nextSection - afterHeader
  }
  val sectionBody = text.substring(afterHeader, sectionLen)

  val lines = Str.split(sectionBody, "\n")
  val lineIdx = indexOfVersionLine(lines)
  if lineIdx < 0 {
    return Err("could not find a 'version = \"...\"' entry in [package] section")
  }
  val line = lines[lineIdx]

  val eqPos = line.indexOf("=")
  val afterEq = line.substring(eqPos + 1)
  val relOpen = afterEq.indexOf("\"")
  if relOpen < 0 {
    return Err("version value in [package] section is not a quoted string")
  }
  val quoteOpen = eqPos + 1 + relOpen
  val afterOpen = line.substring(quoteOpen + 1)
  val relClose = afterOpen.indexOf("\"")
  if relClose < 0 {
    return Err("version value in [package] section is not a properly closed quoted string")
  }
  val quoteClose = quoteOpen + 1 + relClose
  val actualOld = line.substring(quoteOpen + 1, quoteClose - quoteOpen - 1)
  if actualOld != oldVersion {
    return Err(
      "could not find version = \"" + oldVersion + "\" in [package] section (found \"" + actualOld +
        "\" instead)"
    )
  }

  val newLine = line.substring(0, quoteOpen + 1) + newVersion + line.substring(quoteClose, line.length - quoteClose)

  val outLines: List[String] = newList()
  var li = 0
  while li < lines.length {
    if li == lineIdx {
      outLines.add(newLine)
    } else {
      outLines.add(lines[li])
    }
    li += 1
  }
  val newSectionBody = Str.joinList("\n", outLines)

  // Reconstruct: prefix + header + updated-section-body + file-suffix.
  val before = text.substring(0, pkgStart)
  val suffixStart = afterHeader + sectionLen
  val suffix = text.substring(suffixStart, text.length - suffixStart)

  Ok(before + pkgHeader + newSectionBody + suffix)
}

// Read `filePath`, replace the [package] version, and write the file back.
// Prints `<name>: <old> → <new>` on success.
func updateVersionInFile(filePath: in String, newVersion: in String): Int {
  val text = match File.readText(filePath) {
    case Err(e) -> {
      printErr("version: cannot read " + filePath + ": " + IOError.message(e))
      return 1
    }
    case Ok(t) -> t
  }
  val manifest = match Mf.parseManifest(text, filePath) {
    case Err(e) -> {
      printErr("version: cannot parse " + filePath + ": " + ManifestError.message(e))
      return 1
    }
    case Ok(m) -> m
  }
  val oldVersion = manifest.packageSection.version
  if oldVersion == newVersion {
    Console.println(manifest.packageSection.name + ": " + oldVersion + " (unchanged)")
    return 0
  }
  val updated = match replaceVersionInToml(text, oldVersion, newVersion) {
    case Err(msg) -> {
      printErr("version: " + filePath + ": " + msg)
      return 1
    }
    case Ok(t) -> t
  }
  match File.writeText(filePath, updated) {
    case Err(e) -> {
      printErr("version: cannot write " + filePath + ": " + IOError.message(e))
      return 1
    }
    case Ok(_) -> ()
  }
  Console.println(manifest.packageSection.name + ": " + oldVersion + " -> " + newVersion)
  0
}

// Workspace-wide version print/update.
func cmdVersionWorkspace(newVersion: in String, startDir: in String): Int {
  val wsCtx = match Ws.findWorkspaceRoot(startDir) {
    case None -> {
      printErr("version: no workspace root found from " + startDir)
      printErr("  Hint: a workspace root has a [workspace] table in its lyric.toml")
      return 1
    }
    case Some(ctx) -> ctx
  }

  if newVersion.length > 0 {
    var exitCode = 0
    for member in wsCtx.members.toArray() {
      val mfPath = Path.join(member.dir, "lyric.toml")
      if not File.fileExists(mfPath) {
        printErr("version: warning: " + member.name + ": no lyric.toml at " + mfPath)
        continue
      }
      val code = updateVersionInFile(mfPath, newVersion)
      if code != 0 {
        exitCode = code
      }
    }
    // Also update the workspace root manifest if it carries a [package] section
    // (non-virtual workspaces only).
    val rootText = match File.readText(wsCtx.rootFile) {
      case Err(_) -> ""
      case Ok(t) -> t
    }
    if rootText.indexOf("[package]") >= 0 {
      val code = updateVersionInFile(wsCtx.rootFile, newVersion)
      if code != 0 {
        exitCode = code
      }
    }
    return exitCode
  }

  // Print each member's version and flag misalignment.
  var firstVersion = ""
  var aligned = true
  for member in wsCtx.members.toArray() {
    val mfPath = Path.join(member.dir, "lyric.toml")
    if not File.fileExists(mfPath) {
      Console.println("  " + member.name + ": (no lyric.toml)")
      continue
    }
    val ver = match File.readText(mfPath) {
      case Err(_) -> "(read error)"
      case Ok(t) -> match Mf.parseManifest(t, mfPath) {
        case Err(_) -> "(parse error)"
        case Ok(m) -> m.packageSection.version
      }
    }
    Console.println("  " + member.name + " " + ver)
    if firstVersion.length == 0 {
      firstVersion = ver
    } else if ver != firstVersion {
      aligned = false
    }
  }
  // The workspace root is folded in symmetrically with the `--set` path
  // above: a non-virtual root (one that carries its own [package] section)
  // is printed and included in the alignment check too, so `--set` never
  // silently touches a file the print path didn't already report on (#3978).
  val rootText = match File.readText(wsCtx.rootFile) {
    case Err(_) -> ""
    case Ok(t) -> t
  }
  if rootText.indexOf("[package]") >= 0 {
    val rootVer = match Mf.parseManifest(rootText, wsCtx.rootFile) {
      case Err(_) -> "(parse error)"
      case Ok(m) -> m.packageSection.version
    }
    Console.println("  (root) " + rootVer)
    if firstVersion.length == 0 {
      firstVersion = rootVer
    } else if rootVer != firstVersion {
      aligned = false
    }
  }
  if not aligned {
    printErr("warning: workspace members have misaligned versions")
    printErr("  Use 'lyric version --workspace --set <semver>' to align them")
    return 1
  }
  0
}

pub func cmdVersion(argv: in slice[String]): Int {
  var newVersion = ""
  var workspace = false
  var manifestPath: Option[String] = None

  var i = 1  // skip "version"
  while i < argv.length {
    val arg = argv[i]
    if arg == "--set" {
      i += 1
      if i >= argv.length {
        printErr("version: --set requires a semver argument")
        return 1
      }
      newVersion = argv[i]
    } else if arg == "--workspace" {
      workspace = true
    } else if arg == "--manifest" {
      i += 1
      if i >= argv.length {
        printErr("version: --manifest requires a path argument")
        return 1
      }
      manifestPath = Some(value = argv[i])
    } else if Str.startsWith(arg, "-") {
      printErr("version: unknown flag: " + arg)
      return 1
    }
    i += 1
  }

  if newVersion.length > 0 {
    val err = validateSemver(newVersion)
    if err.length > 0 {
      printErr("version: " + err)
      return 1
    }
  }

  val startDir = match manifestPath {
    case Some(p) -> Path.dirname(p)
    case None -> Environment.currentDirectory()
  }

  if workspace {
    return cmdVersionWorkspace(newVersion, startDir)
  }

  // Single-package mode.
  val mfPath = match discoverManifest(manifestPath) {
    case None -> {
      printErr("version: no lyric.toml found (use --manifest to specify one, or --workspace for a workspace)")
      return 1
    }
    case Some(p) -> p
  }

  if newVersion.length > 0 {
    return updateVersionInFile(mfPath, newVersion)
  }

  // Print the current version.
  val text = match File.readText(mfPath) {
    case Err(e) -> {
      printErr("version: cannot read " + mfPath + ": " + IOError.message(e))
      return 1
    }
    case Ok(t) -> t
  }
  match Mf.parseManifest(text, mfPath) {
    case Err(e) -> {
      printErr("version: cannot parse " + mfPath + ": " + ManifestError.message(e))
      return 1
    }
    case Ok(m) -> {
      Console.println(m.packageSection.name + " " + m.packageSection.version)
      return 0
    }
  }
}
