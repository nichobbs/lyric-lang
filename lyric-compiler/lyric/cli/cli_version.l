package Lyric.Cli

import Std.Core
import Std.Collections
import Std.Console as Console
import Std.File as File
import Std.String as Str
import Std.Path as Path
import Std.Environment as Environment
import Std.Errors
import Lyric.Manifest as Mf
import Lyric.Workspace as Ws
import Lyric.Discovery as Disc

// ─────────────────────────────────────────────────────────────────────────────
// §14. lyric version — print and update package versions
// ─────────────────────────────────────────────────────────────────────────────

// Return "" if `v` looks like a valid semver (MAJOR.MINOR.PATCH[+-suffix]),
// or a human-readable diagnostic string if not.
func validateSemver(v: in String): String {
  if v.length == 0 {
    return "version cannot be empty"
  }
  val first = v.indexOf(".")
  if first <= 0 {
    return "invalid semver '" + v + "': expected MAJOR.MINOR.PATCH"
  }
  val second = v.indexOf(".", first + 1)
  if second <= first + 1 {
    return "invalid semver '" + v + "': expected MAJOR.MINOR.PATCH"
  }
  ""
}

// Replace `version = "<oldVersion>"` with `version = "<newVersion>"` inside
// the [package] section of a lyric.toml text.  The [package] section boundary
// is determined by the next section header (`\n[`), or end-of-file.
// Returns the updated text or an error string.
func replaceVersionInToml(
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

  val versionKey = "version = \"" + oldVersion + "\""
  val vkPos = sectionBody.indexOf(versionKey)
  if vkPos < 0 {
    return Err("could not find version = \"" + oldVersion + "\" in [package] section")
  }
  val newVersionKey = "version = \"" + newVersion + "\""

  // Reconstruct: prefix + header + section-before-version + new-key +
  // section-after-version + file-suffix.
  val before = text.substring(0, pkgStart)
  val bodyBefore = sectionBody.substring(0, vkPos)
  val bodyAfterStart = vkPos + versionKey.length
  val bodyAfter = sectionBody.substring(bodyAfterStart, sectionBody.length - bodyAfterStart)
  val suffixStart = afterHeader + sectionLen
  val suffix = text.substring(suffixStart, text.length - suffixStart)

  Ok(before + pkgHeader + bodyBefore + newVersionKey + bodyAfter + suffix)
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
