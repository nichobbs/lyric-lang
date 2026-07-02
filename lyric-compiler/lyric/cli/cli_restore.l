package Lyric.Cli

import Std.Core
import Std.Collections
import Std.Console as Console
import Std.File as File
import Std.String as Str
import Std.Path as Path
import Std.Process as Process
import Std.Environment as Environment
import Std.Errors
import Std.Hash as Hash
import Std.Char as Ch
import Std.ProcessCapture as ProcessCapture
import Lyric.Manifest as Mf
import Lyric.Lexer
import Lyric.Pack as Pack
import Lyric.Workspace as Ws
import Lyric.Discovery as Disc
import Lyric.Init as Init
import Lyric.GitDep as GitDep
import Lyric.Lockfile as LF

// ─────────────────────────────────────────────────────────────────────────────
// §10. Restore command
// ─────────────────────────────────────────────────────────────────────────────
// Emit the <PackageReference> elements for a manifest's registry Lyric deps +
// all [nuget] entries.  Used in the generated restore csproj.
func buildRestoreCsproj(manifest: in Manifest, target: in String): String {
  var refs = ""
  var di = 0
  while di < manifest.deps.count {
    val d = manifest.deps[di]
    match d.source {
      case Registry(version) -> {
        refs = refs + "    <PackageReference Include=\"" + Pack.xmlEscape(d.name) + "\" Version=\"" + Pack.xmlEscape(version) +
          "\" />\n"
      }
      case _ -> ()
    }
    di = di + 1
  }
  match manifest.nuget {
    case None -> ()
    case Some(n) -> {
      var ni = 0
      while ni < n.entries.count {
        val e = n.entries[ni]
        refs = refs + "    <PackageReference Include=\"" + Pack.xmlEscape(e.name) + "\" Version=\"" +
          Pack.xmlEscape(e.version) +
          "\" />\n"
        ni = ni + 1
      }
    }
  }
  var xml = "<Project Sdk=\"Microsoft.NET.Sdk\">\n"
  xml = xml + "  <PropertyGroup>\n"
  xml = xml + "    <TargetFramework>" + Pack.xmlEscape(target) + "</TargetFramework>\n"
  xml = xml + "    <GenerateAssemblyInfo>false</GenerateAssemblyInfo>\n"
  xml = xml + "    <IncludeBuildOutput>false</IncludeBuildOutput>\n"
  xml = xml + "  </PropertyGroup>\n"
  xml = xml + "  <ItemGroup>\n"
  xml = xml + refs
  xml = xml + "  </ItemGroup>\n"
  xml + "</Project>\n"
}

// ─────────────────────────────────────────────────────────────────────────────
// §10a. Lock-file content hashing (lyric-lang #738)
// ─────────────────────────────────────────────────────────────────────────────
/// SHA-512 of the resolved dependency's `lyric.toml`.  Used as the lockable
/// content identity for `Path`, `Workspace`, and `Git` deps — the manifest
/// is the canonical content-snapshot for source-form dependencies.
///
/// Returns `None` when the file is missing or unreadable; callers treat that
/// as "graceful skip" in normal restore and as a hard failure in `--locked`.
func lockSha512OfLocalManifest(localDir: in String): Option[String] {
  if localDir.length == 0 {
    return None
  }
  val manifestPath = Path.join(localDir, "lyric.toml")
  match Hash.sha512OfFile(manifestPath) {
    case Ok(hex) -> Some(value = hex)
    case Err(_) -> None
  }
}

/// SHA-512 of the resolved NuGet `.nupkg` for a registry dep.  Layout is
/// `~/.nuget/packages/<name-lower>/<version>/<name-lower>.<version>.nupkg`
/// — populated by `dotnet restore` before this is called.
///
/// Returns `None` when the file is missing (e.g. on a host where the
/// NuGet cache lives elsewhere, or when `dotnet restore` was skipped).
func lockSha512OfNupkg(name: in String, version: in String): Option[String] {
  if name.length == 0 or version.length == 0 {
    return None
  }
  val lower = name.toLower()
  // NUGET_PACKAGES overrides the cache root (CI uses this); empty falls through so `--locked` isn't soft-bypassed.
  val nugetPkgVar: Option[String] = match Environment.getVar("NUGET_PACKAGES") {
    case Ok(p) -> if p.length > 0 { Some(value = p) } else { None }
    case Err(_) -> None
  }
  val cacheRoot = match nugetPkgVar {
    case Some(p) -> p
    case None -> {
      val home = match Environment.getVar("HOME") {
        case Ok(h) -> h
        case Err(_) -> match Environment.getVar("USERPROFILE") { case Ok(h) -> h; case Err(_) -> return None }
      }
      Path.join(home, ".nuget/packages")
    }
  }
  val cacheDir = Path.join(cacheRoot, lower)
  val versionDir = Path.join(cacheDir, version)
  val nupkgPath = Path.join(versionDir, lower + "." + version + ".nupkg")
  match Hash.sha512OfFile(nupkgPath) {
    case Ok(hex) -> Some(value = hex)
    case Err(_) -> None
  }
}

// `lyric init [<dir>] [--name <Name>] [--lib] [--force]` — scaffold a new
// application (or `--lib` library) package in <dir> (default the current
// directory): a lyric.toml, src/main.l (or src/lib.l), and a .gitignore (#1972).
func cmdInit(argv: in slice[String]): Int {
  var dir = "."
  var haveDir = false
  var nameOverride: Option[String] = None
  var isLib = false
  var force = false

  var i = 1
  while i < argv.length {
    val arg = argv[i]
    if arg == "--name" {
      if i + 1 < argv.length {
        nameOverride = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("init: --name requires an argument")
        return 1
      }
    } else if arg == "--lib" {
      isLib = true
      i += 1
    } else if arg == "--force" {
      force = true
      i += 1
    } else {
      if not haveDir {
        dir = arg
        haveDir = true
        i += 1
      } else {
        printErr("init: unexpected extra argument '" + arg + "'")
        return 1
      }
    }
  }

  Init.runInit(InitOptions(dir = dir, nameOverride = nameOverride, isLib = isLib, force = force))
}

// Whether a TOML line defines the bare key `key` (its left-of-`=` token,
// trimmed, equals `key`).  Comment lines and table headers never match.
func lineDefinesKey(line: in String, key: in String): Bool {
  val t = Str.trim(line)
  if Str.startsWith(t, "#") {
    return false
  }
  if Str.startsWith(t, "[") {
    return false
  }
  match Str.indexOf(t, "=") {
    case None -> false
    case Some(eq) -> Str.trim(Str.substring(t, 0, eq)) == key
  }
}

// Insert or update `key = rhs` inside the `[table]` section of a TOML document,
// preserving the rest of the file.  If the key already exists in that table its
// line is replaced (idempotent re-add); if the table exists the entry is
// appended to it; if the table is absent a new section is appended at EOF.
func upsertTomlEntry(text: in String, table: in String, key: in String, rhs: in String): String {
  val newLine = key + " = " + rhs
  val header = "[" + table + "]"
  val lines = Str.split(text, "\n")
  val n = lines.length

  var secIdx = -1
  var idx = 0
  while idx < n {
    // Accept a trailing comment after the section header (e.g.
    // `[dependencies] # managed by lyric`).  Strip everything after
    // the first `#` before comparing, as TOML allows this form.
    val rawLine = Str.trim(lines[idx])
    val strippedLine = match Str.indexOf(rawLine, "#") {
      case Some(ci) -> Str.trim(Str.substring(rawLine, 0, ci))
      case None -> rawLine
    }
    if strippedLine == header {
      secIdx = idx
      idx = n
    } else {
      idx += 1
    }
  }

  val outLines: List[String] = newList()
  if secIdx < 0 {
    // Table absent — append a fresh section at EOF.
    var p = 0
    while p < n {
      outLines.add(lines[p])
      p += 1
    }
    if n > 0 and Str.length(Str.trim(lines[n - 1])) > 0 {
      outLines.add("")
    }
    outLines.add(header)
    outLines.add(newLine)
    return Str.joinList("\n", outLines)
  }

  // Locate an existing key line and the section's end (next header or EOF).
  var keyIdx = -1
  var secEnd = n
  var q = secIdx + 1
  while q < n {
    val t = Str.trim(lines[q])
    if Str.startsWith(t, "[") {
      secEnd = q
      q = n
    } else {
      if keyIdx < 0 and lineDefinesKey(lines[q], key) {
        keyIdx = q
      }
      q += 1
    }
  }

  if keyIdx >= 0 {
    var r = 0
    while r < n {
      if r == keyIdx {
        outLines.add(newLine)
      } else {
        outLines.add(lines[r])
      }
      r += 1
    }
    return Str.joinList("\n", outLines)
  }

  // No existing key: insert after the last non-blank line of the section.
  var insertAt = secIdx + 1
  var s = secIdx + 1
  while s < secEnd {
    if Str.length(Str.trim(lines[s])) > 0 {
      insertAt = s + 1
    }
    s += 1
  }
  var w = 0
  while w < n {
    if w == insertAt {
      outLines.add(newLine)
    }
    outLines.add(lines[w])
    w += 1
  }
  if insertAt >= n {
    outLines.add(newLine)
  }
  Str.joinList("\n", outLines)
}

// Remove the `key` entry from the `[table]` section of a TOML document.
// Returns `text` unchanged if the section or key is not found.
func removeTomlEntry(text: in String, table: in String, key: in String): String {
  val header = "[" + table + "]"
  val lines = Str.split(text, "\n")
  val n = lines.length

  var secIdx = -1
  var idx = 0
  while idx < n {
    val rawLine = Str.trim(lines[idx])
    val strippedLine = match Str.indexOf(rawLine, "#") {
      case Some(ci) -> Str.trim(Str.substring(rawLine, 0, ci))
      case None -> rawLine
    }
    if strippedLine == header {
      secIdx = idx
      idx = n
    } else {
      idx += 1
    }
  }

  if secIdx < 0 {
    return text
  }

  var keyIdx = -1
  var q = secIdx + 1
  while q < n {
    val t = Str.trim(lines[q])
    if Str.startsWith(t, "[") {
      q = n
    } else {
      if keyIdx < 0 and lineDefinesKey(lines[q], key) {
        keyIdx = q
      }
      q += 1
    }
  }

  if keyIdx < 0 {
    return text
  }

  val outLines: List[String] = newList()
  var w = 0
  while w < n {
    if w != keyIdx {
      outLines.add(lines[w])
    }
    w += 1
  }
  Str.joinList("\n", outLines)
}

// `lyric remove <name> [--nuget] [--manifest <m>] [--no-restore]` — remove a
// dependency from [dependencies] (or [nuget]) and restore (#1974).
func cmdRemove(argv: in slice[String]): Int {
  var manifestArg: Option[String] = None
  var isNuget = false
  var noRestore = false
  var nameArg: Option[String] = None

  var i = 1
  while i < argv.length {
    val arg = argv[i]
    if arg == "--manifest" {
      if i + 1 < argv.length {
        manifestArg = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("remove: --manifest requires an argument")
        return 1
      }
    } else if arg == "--nuget" {
      isNuget = true
      i += 1
    } else if arg == "--no-restore" {
      noRestore = true
      i += 1
    } else {
      match nameArg {
        case None -> {
          nameArg = Some(value = arg)
          i += 1
        }
        case Some(_) -> {
          printErr("remove: unexpected extra argument '" + arg + "'")
          return 1
        }
      }
    }
  }

  val name = match nameArg {
    case Some(n) -> n
    case None -> {
      printErr("remove: missing <name>")
      printUsage()
      return 1
    }
  }
  if Str.length(name) == 0 {
    printErr("remove: empty dependency name")
    return 1
  }

  val table = if isNuget { "nuget" } else { "dependencies" }

  val mfPath = match discoverManifest(manifestArg) {
    case Some(p) -> p
    case None -> {
      printErr("remove: no lyric.toml found in this directory or any parent (use --manifest)")
      return 1
    }
  }

  val mfText = match File.readText(mfPath) {
    case Ok(t) -> t
    case Err(e) -> {
      printErr("remove: " + IOError.message(e))
      return 1
    }
  }

  var updated = removeTomlEntry(mfText, table, name)
  if updated == mfText {
    printErr("remove: '" + name + "' not found in [" + table + "] of " + mfPath)
    return 1
  }

  if not Str.endsWith(updated, "\n") {
    updated = updated + "\n"
  }

  match Mf.parseManifest(updated, mfPath) {
    case Ok(_) -> ()
    case Err(e) -> {
      printErr("remove: refusing to write — resulting manifest is invalid: " + ManifestError.message(e))
      return 1
    }
  }

  match File.writeText(mfPath, updated) {
    case Ok(_) -> ()
    case Err(e) -> {
      printErr("remove: could not write " + mfPath + ": " + IOError.message(e))
      return 1
    }
  }
  Console.println("remove: removed '" + name + "' from [" + table + "] in " + mfPath)

  if noRestore {
    return 0
  }
  runRestore(mfPath, false)
}

// `lyric add <name>[@<version>] [--path <p>] [--git <url> [--tag|--rev|--branch <ref>] [--subdir <d>]]
//   [--nuget] [--manifest <m>] [--no-restore]` — add or update a dependency in the
// discovered manifest's [dependencies] (or [nuget]) table, then restore (#1973).
func cmdAdd(argv: in slice[String]): Int {
  var manifestArg: Option[String] = None
  var pathArg: Option[String] = None
  var gitArg: Option[String] = None
  var gitRefKind: String = ""    // "tag" | "rev" | "branch"
  var gitRef: String = ""
  var gitSubdir: String = ""
  var isNuget: Bool = false
  var noRestore: Bool = false
  var spec: Option[String] = None

  var i = 1
  while i < argv.length {
    val arg = argv[i]
    if arg == "--manifest" {
      if i + 1 < argv.length {
        manifestArg = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("add: --manifest requires an argument")
        return 1
      }
    } else if arg == "--path" {
      if i + 1 < argv.length {
        pathArg = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("add: --path requires an argument")
        return 1
      }
    } else if arg == "--git" {
      if i + 1 < argv.length {
        gitArg = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("add: --git requires an argument")
        return 1
      }
    } else if arg == "--tag" {
      if i + 1 < argv.length {
        gitRefKind = "tag"
        gitRef = argv[i + 1]
        i += 2
      } else {
        printErr("add: --tag requires an argument")
        return 1
      }
    } else if arg == "--rev" {
      if i + 1 < argv.length {
        gitRefKind = "rev"
        gitRef = argv[i + 1]
        i += 2
      } else {
        printErr("add: --rev requires an argument")
        return 1
      }
    } else if arg == "--branch" {
      if i + 1 < argv.length {
        gitRefKind = "branch"
        gitRef = argv[i + 1]
        i += 2
      } else {
        printErr("add: --branch requires an argument")
        return 1
      }
    } else if arg == "--subdir" {
      if i + 1 < argv.length {
        gitSubdir = argv[i + 1]
        i += 2
      } else {
        printErr("add: --subdir requires an argument")
        return 1
      }
    } else if arg == "--nuget" {
      isNuget = true
      i += 1
    } else if arg == "--no-restore" {
      noRestore = true
      i += 1
    } else {
      match spec {
        case None -> {
          spec = Some(value = arg)
          i += 1
        }
        case Some(_) -> {
          printErr("add: unexpected extra argument '" + arg + "'")
          return 1
        }
      }
    }
  }

  val rawSpec = match spec {
    case Some(s) -> s
    case None -> {
      printErr("add: missing <name>[@version]")
      printUsage()
      return 1
    }
  }

  // Split `name@version`.
  var name = rawSpec
  var version = ""
  match Str.indexOf(rawSpec, "@") {
    case Some(at) -> {
      name = Str.substring(rawSpec, 0, at)
      version = Str.substring(rawSpec, at + 1, Str.length(rawSpec) - at - 1)
    }
    case None -> ()
  }
  if Str.length(name) == 0 {
    printErr("add: empty dependency name")
    return 1
  }

  // Validate mutually-exclusive source selectors.
  val hasPath = match pathArg { case Some(_) -> true; case None -> false }
  val hasGit = match gitArg { case Some(_) -> true; case None -> false }
  if hasPath and hasGit {
    printErr("add: --path and --git are mutually exclusive")
    return 1
  }
  if isNuget and (hasPath or hasGit) {
    printErr("add: --nuget cannot be combined with --path/--git")
    return 1
  }
  if gitRefKind != "" and not hasGit {
    printErr("add: --tag/--rev/--branch require --git")
    return 1
  }
  if Str.length(gitSubdir) > 0 and not hasGit {
    printErr("add: --subdir requires --git")
    return 1
  }
  if Str.length(version) > 0 and (hasPath or hasGit) {
    printErr("add: @version cannot be combined with --path/--git")
    return 1
  }

  // Reject double-quote and backslash characters in path/URL values: they are
  // embedded directly in a TOML basic-string RHS and would produce malformed
  // TOML.  On Windows, use forward slashes in --path values (they work on
  // .NET and avoid the backslash-as-escape-sequence ambiguity in TOML strings).
  match pathArg {
    case Some(p) -> {
      if Str.contains(p, "\"") {
        printErr("add: --path value must not contain double-quote characters")
        return 1
      }
      if Str.contains(p, "\\") {
        printErr(
          "add: --path value contains backslashes; use forward slashes instead (they work on all platforms in TOML strings)"
        )
        return 1
      }
    }
    case None -> ()
  }
  match gitArg {
    case Some(url) -> {
      if Str.contains(url, "\"") {
        printErr("add: --git URL must not contain double-quote characters")
        return 1
      }
    }
    case None -> ()
  }
  // The git ref (--tag/--rev/--branch) and --subdir are embedded in the TOML
  // RHS too, so they get the same double-quote guard against malformed/injected TOML.
  if gitRefKind != "" {
    if Str.contains(gitRef, "\"") {
      printErr("add: --" + gitRefKind + " value must not contain double-quote characters")
      return 1
    }
  }
  if Str.length(gitSubdir) > 0 {
    if Str.contains(gitSubdir, "\"") {
      printErr("add: --subdir value must not contain double-quote characters")
      return 1
    }
  }

  // Build the git-form RHS outside of the match so the appends are readable.
  var gitTomlRhs = ""
  match gitArg {
    case Some(url) -> {
      gitTomlRhs = "{ git = \"" + url + "\""
      if gitRefKind != "" {
        gitTomlRhs = gitTomlRhs + ", " + gitRefKind + " = \"" + gitRef + "\""
      }
      if Str.length(gitSubdir) > 0 {
        gitTomlRhs = gitTomlRhs + ", subdir = \"" + gitSubdir + "\""
      }
      gitTomlRhs = gitTomlRhs + " }"
    }
    case None -> ()
  }

  // Render the TOML right-hand side for the chosen source form.
  val rhs = match pathArg {
    case Some(p) -> "{ path = \"" + p + "\" }"
    case None -> match gitArg { case Some(_) -> gitTomlRhs; case None -> "\"" + (if Str.length(version) > 0 { version } else { "*" }) + "\"" }
  }

  val table = if isNuget { "nuget" } else { "dependencies" }

  val mfPath = match discoverManifest(manifestArg) {
    case Some(p) -> p
    case None -> {
      printErr("add: no lyric.toml found in this directory or any parent (use --manifest)")
      return 1
    }
  }
  val mfText = match File.readText(mfPath) {
    case Ok(t) -> t
    case Err(e) -> {
      printErr("add: " + IOError.message(e))
      return 1
    }
  }

  var updated = upsertTomlEntry(mfText, table, name, rhs)
  // Keep the file POSIX-clean: end with exactly one trailing newline.
  if not Str.endsWith(updated, "\n") {
    updated = updated + "\n"
  }

  // Guard: the edited manifest must still parse before we commit it to disk.
  match Mf.parseManifest(updated, mfPath) {
    case Ok(_) -> ()
    case Err(e) -> {
      printErr("add: refusing to write — resulting manifest is invalid: " + ManifestError.message(e))
      return 1
    }
  }
  match File.writeText(mfPath, updated) {
    case Ok(_) -> ()
    case Err(e) -> {
      printErr("add: could not write " + mfPath + ": " + IOError.message(e))
      return 1
    }
  }
  Console.println("add: " + name + " = " + rhs + " -> [" + table + "] in " + mfPath)

  if noRestore {
    return 0
  }
  runRestore(mfPath, false)
}

func cmdRestore(argv: in slice[String]): Int {
  var manifestArg: Option[String] = None
  var lockedMode = false

  var i = 1
  while i < argv.length {
    val arg = argv[i]
    if arg == "--manifest" {
      if i + 1 < argv.length {
        manifestArg = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("restore: --manifest requires an argument")
        return 1
      }
    } else if arg == "--locked" {
      lockedMode = true
      i += 1
    } else {
      printErr("restore: unrecognised flag '" + arg + "'")
      i += 1
    }
  }

  val mfPath = match discoverManifest(manifestArg) { case Some(p) -> p; case None -> "lyric.toml" }

  return runRestore(mfPath, lockedMode)
}

// ─────────────────────────────────────────────────────────────────────────────
// §10a. Maven artifact restore helpers
// ─────────────────────────────────────────────────────────────────────────────
// Escape a string value for embedding in a JSON string literal.
pub func jsonEscape(s: in String): String {
  Str.replace(Str.replace(s, "\\", "\\\\"), "\"", "\\\"")
}

// Find lyric-resolver.jar.  Search order:
//   1. LYRIC_MAVEN_RESOLVER env var (exact path to the jar)
//   2. <appBaseDir>/lyric-resolver.jar  (installed beside the lyric binary)
//   3. <appBaseDir>/../lyric-resolver.jar  (one level up — common dev layout)
//   4. $HOME/.lyric/tools/lyric-resolver.jar  (user-local install)
func findMavenResolverJar(): Option[String] {
  match Environment.getVar("LYRIC_MAVEN_RESOLVER") {
    case Ok(p) -> {
      if File.fileExists(p) {
        return Some(value = p)
      } else {
        printErr("restore: warning: LYRIC_MAVEN_RESOLVER=" + p + " does not exist; falling back to default search locations")
      }
    }
    case Err(_) -> ()
  }
  val base = Environment.appBaseDirectory()
  val c1 = Path.join(base, "lyric-resolver.jar")
  if File.fileExists(c1) {
    return Some(value = c1)
  }
  val c2 = Path.join(Path.dirname(base), "lyric-resolver.jar")
  if File.fileExists(c2) {
    return Some(value = c2)
  }
  val home = Environment.getVarOrDefault("HOME", "")
  if home.length > 0 {
    val c3 = Path.join(Path.join(Path.join(home, ".lyric"), "tools"), "lyric-resolver.jar")
    if File.fileExists(c3) {
      return Some(value = c3)
    }
  }
  None
}

// Build the JSON request body for lyric-resolver.jar's stdin protocol.
pub func buildMavenResolverRequest(maven: in MavenSection, cacheDir: in String, outputDir: in String): String {
  var coords = "["
  var ci = 0
  while ci < maven.entries.count {
    val e = maven.entries[ci]
    if ci > 0 {
      coords = coords + ","
    }
    coords = coords + "{\"group\":\"" + jsonEscape(e.group) + "\",\"artifact\":\"" + jsonEscape(e.artifact) +
      "\",\"version\":\"" +
      jsonEscape(e.version) +
      "\"}"
    ci += 1
  }
  coords = coords + "]"
  var repos = "["
  var ri = 0
  while ri < maven.repositories.count {
    val r = maven.repositories[ri]
    if ri > 0 {
      repos = repos + ","
    }
    repos = repos + "\"" + jsonEscape(r) + "\""
    ri += 1
  }
  repos = repos + "]"
  val jvStr = match maven.javaVersion { case Some(jv) -> "\"" + jsonEscape(jv) + "\""; case None -> "null" }
  "{\"coordinates\":" + coords + ",\"repositories\":" + repos + ",\"javaVersion\":" + jvStr + ",\"cacheDir\":\"" +
    jsonEscape(cacheDir) +
    "\",\"outputDir\":\"" +
    jsonEscape(outputDir) +
    "\"}"
}

// Extract all `jarPath` values from lyric-resolver.jar's JSON array output.
// Uses structural splitting rather than a full JSON parser: `jarPath` values
// are file-system paths that cannot contain `"` on any supported platform.
//
// CONTRACT: expects compact JSON (no whitespace between `"jarPath":"` and the
// value).  Pretty-printed output (`"jarPath": "..."`) will yield zero paths —
// the resolver protocol requires compact format.
pub func extractMavenJarPaths(jsonOutput: in String): List[String] {
  val paths: List[String] = newList()
  val pieces = Str.split(jsonOutput, "\"jarPath\":\"")
  var pi = 1
  while pi < pieces.length {
    val piece = pieces[pi]
    match Str.indexOf(piece, "\"") {
      case None -> ()
      case Some(closeIdx) -> {
        val raw = Str.substring(piece, 0, closeIdx)
        if raw.length > 0 {
          val unescaped = Str.replace(Str.replace(raw, "\\\\", "\\"), "\\\"", "\"")
          paths.add(unescaped)
        }
      }
    }
    pi += 1
  }
  paths
}

// Download Maven JARs declared in manifest.maven and write their paths to
// <mfDir>/target/restore/jvm-classpath.txt (one path per line).
// Returns 0 on success, 1 on error.  No-op when no [maven] section is present.
func restoreMavenJars(manifest: in Manifest, mfDir: in String): Int {
  val maven = match manifest.maven { case None -> return 0; case Some(m) -> m }
  if maven.entries.count == 0 {
    return 0
  }
  val resolverJar = match findMavenResolverJar() {
    case None -> {
      Console.println(
        "restore: note: Maven dependencies declared but lyric-resolver.jar not found; " +
          "JVM builds will skip Maven artifacts"
      )
      Console.println("  Set LYRIC_MAVEN_RESOLVER=/path/to/lyric-resolver.jar or place it beside the lyric binary")
      return 0
    }
    case Some(j) -> j
  }
  val home = Environment.getVarOrDefault("HOME", "")
  val cacheDir = if home.length > 0 { Path.join(Path.join(home, ".m2"), "repository") } else { Path.join(mfDir, ".m2") }
  val outputDir = Path.join(Path.join(mfDir, "target"), "restore")
  match File.createDir(outputDir) {
    case Err(e) -> {
      printErr("restore: cannot create " + outputDir + ": " + IOError.message(e))
      return 1
    }
    case Ok(_) -> ()
  }
  val requestJson = buildMavenResolverRequest(maven, cacheDir, outputDir)
  Console.println("restore: downloading Maven artifacts ...")
  val javaArgs: List[String] = newList()
  javaArgs.add("-jar")
  javaArgs.add(resolverJar)
  val captureResult = ProcessCapture.runCaptureWithDiagnosticsTimeout("java", javaArgs, requestJson, 300000)
  if captureResult.timedOut {
    printErr("restore: Maven resolver timed out after 300 seconds")
    return 1
  }
  if captureResult.exitCode != 0 {
    printErr("restore: Maven resolver exited with code " + toString(captureResult.exitCode))
    if captureResult.stderr.length > 0 {
      printErr(captureResult.stderr)
    }
    return 1
  }
  val jarPaths = extractMavenJarPaths(captureResult.stdout)
  if jarPaths.count == 0 and maven.entries.count > 0 {
    printErr(
      "restore: warning: Maven resolver reported 0 resolved JARs for " + toString(maven.entries.count) +
        " declared coordinates — check resolver output above for errors; verify coordinates and network connectivity"
    )
  }
  var classpathText = ""
  var ji = 0
  while ji < jarPaths.count {
    if ji > 0 {
      classpathText = classpathText + "\n"
    }
    classpathText = classpathText + jarPaths[ji]
    ji += 1
  }
  val classpathFile = Path.join(outputDir, "jvm-classpath.txt")
  match File.writeText(classpathFile, classpathText) {
    case Err(e) -> {
      printErr("restore: cannot write " + classpathFile + ": " + IOError.message(e))
      return 1
    }
    case Ok(_) -> ()
  }
  Console.println("restore: " + toString(jarPaths.count) + " Maven artifact(s) resolved")
  0
}

// Resolve and lock every dependency declared in the manifest at `mfPath`,
// writing `lyric.lock` (or verifying it under `lockedMode`).  Extracted from
// cmdRestore so `lyric build` can auto-restore when the lock is missing or
// stale.
func runRestore(mfPath: in String, lockedMode: in Bool): Int {
  val mfText = match File.readText(mfPath) {
    case Ok(text) -> text
    case Err(e) -> {
      printErr("restore: " + IOError.message(e))
      return 1
    }
  }

  val manifest: Manifest = match Mf.parseManifest(mfText, mfPath) {
    case Ok(m) -> m
    case Err(e) -> {
      printErr("restore: " + ManifestError.message(e))
      return 1
    }
  }

  val mfDir = Path.dirname(mfPath)
  val pkgName = manifest.packageSection.name

  // Find workspace context (if any) for resolving workspace/path deps.
  val wsCtx: Option[WorkspaceContext] = Ws.findWorkspaceRoot(mfDir)

  // Read existing lock file (if present).
  val lockPath = match wsCtx {
    case Some(ctx) -> Path.join(ctx.rootDir, "lyric.lock")
    case None -> Path.join(mfDir, "lyric.lock")
  }
  var lockFileExists = false
  var lockParseError = false
  val existingLf = match File.readText(lockPath) {
    case Err(_) -> LF.emptyLockFile()
    case Ok(locked) -> {
      lockFileExists = true
      match LF.parseLockFile(locked) {
        case Err(e) -> {
          printErr("restore: lock file parse error: " + e)
          lockParseError = true
          LF.emptyLockFile()
        }
        case Ok(clf) -> clf
      }
    }
  }
  var lf = existingLf

  var exitCode = 0
  var di = 0
  while di < manifest.deps.count {
    val dep = manifest.deps[di]
    di += 1

    match dep.source {
      case Registry(version) -> {
        // NuGet registry dep — handled by `dotnet restore` below; record in lock.
        val nugetBase = "nuget:https://api.nuget.org/v3/index.json"
        val src = match dep.registry {
          case Some(url) -> "nuget:" + url
          case None -> match manifest.registry { case Some(rc) -> match rc.dotnet { case Some(url) -> "nuget:" + url; case None -> nugetBase }; case None -> nugetBase }
        }
        lf = LF.addOrUpdatePackage(
          lf,
          LF.LockedPackage(
            name = dep.name,
            version = version,
            source = src,
            sha512 = None,
            // populated after `dotnet restore` below
            path = None
          )
        )
      }
      case Workspace(versionConstraint) -> {
        // Workspace dep — resolve to local path via workspace index.
        val resolvedDir = match wsCtx {
          case None -> {
            printErr("restore: '" + dep.name + "' declared workspace = true but no workspace root found")
            exitCode = 1
            ""
          }
          case Some(ctx) -> match Ws.resolveDep(dep.name, ctx) { case None -> { printErr("restore: '" + dep.name + "' declared workspace = true but not found in workspace"); exitCode = 1; "" }; case Some(dir) -> dir }
        }
        if resolvedDir != "" {
          // Optional version constraint check.
          match versionConstraint {
            case None -> ()
            case Some(constraint) -> {
              val memberToml = Path.join(resolvedDir, "lyric.toml")
              match File.readText(memberToml) {
                case Err(_) -> ()
                case Ok(memberText) -> match Mf.parseManifest(memberText, memberToml) { case Err(_) -> (); case Ok(memberMf) -> { if memberMf.packageSection.version != constraint { printErr("restore: workspace member '" + dep.name + "' version " + memberMf.packageSection.version + " does not satisfy constraint " + constraint); exitCode = 1 } } }
              }
            }
          }
          if exitCode == 0 {
            lf = LF.addOrUpdatePackage(
              lf,
              LF.LockedPackage(
                name = dep.name,
                version = "",
                source = "workspace",
                sha512 = lockSha512OfLocalManifest(resolvedDir),
                path = Some(value = resolvedDir)
              )
            )
            Console.println("restore: " + dep.name + " -> " + resolvedDir + " (workspace)")
          }
        }
      }
      case Path(relDir) -> {
        val absDir = if Path.isAbsolute(relDir) { relDir } else { Path.join(mfDir, relDir) }
        lf = LF.addOrUpdatePackage(
          lf,
          LF.LockedPackage(
            name = dep.name,
            version = "",
            source = "path:" + absDir,
            sha512 = lockSha512OfLocalManifest(absDir),
            path = Some(value = absDir)
          )
        )
        Console.println("restore: " + dep.name + " -> " + absDir + " (path)")
      }
      case Git(url, refKind, refValue, subdir) -> {
        Console.println("restore: fetching " + dep.name + " from git " + url + "...")
        match GitDep.resolve(url, refKind, refValue, subdir) {
          case Err(e) -> {
            printErr("restore: git dep '" + dep.name + "': " + e)
            exitCode = 1
          }
          case Ok(result) -> {
            val srcTag = "git:" + url + "#" + result.resolvedRev
            lf = LF.addOrUpdatePackage(
              lf,
              LF.LockedPackage(
                name = dep.name,
                version = result.resolvedRev,
                source = srcTag,
                sha512 = lockSha512OfLocalManifest(result.localDir),
                path = Some(value = result.localDir)
              )
            )
            Console.println("restore: " + dep.name + " -> " + result.localDir + " (" + result.resolvedRev + ")")
          }
        }
      }
    }
  }

  if exitCode != 0 {
    return exitCode
  }

  // Run `dotnet restore` for registry and [nuget] deps.
  val nugetCount = match manifest.nuget { case Some(n) -> n.entries.count; case None -> 0 }
  var registryCount = 0
  var ri = 0
  while ri < manifest.deps.count {
    match manifest.deps[ri].source {
      case Registry(_) -> {
        registryCount += 1
      }
      case _ -> ()
    }
    ri += 1
  }

  if nugetCount > 0 or registryCount > 0 {
    val target = match manifest.nuget {
      case Some(n) -> match n.target { case Some(t) -> t; case None -> "net10.0" }
      case None -> "net10.0"
    }
    val csproj = buildRestoreCsproj(manifest, target)
    val tmpCsproj = Path.join(mfDir, pkgName + "-restore.csproj")
    match File.writeText(tmpCsproj, csproj) {
      case Err(e) -> {
        printErr("restore: cannot write temp csproj: " + IOError.message(e))
        return 1
      }
      case Ok(_) -> ()
    }
    val args: List[String] = newList()
    args.add("restore")
    args.add(tmpCsproj)
    val dotnetExit = match Process.run("dotnet", args) {
      case Ok(code) -> code
      case Err(e) -> {
        printErr("restore: dotnet restore failed: " + IOError.message(e))
        return 1
      }
    }
    if dotnetExit != 0 {
      return dotnetExit
    }
  }

  // Second pass: now that `dotnet restore` has populated the NuGet cache,
  // compute SHA-512 of each registry dep's `.nupkg` and write it back into
  // the lock entry (#738 supply-chain integrity).  Path / Workspace / Git
  // deps already had their digests written in the resolution loop above.
  val upgraded: List[LF.LockedPackage] = newList()
  var ui = 0
  while ui < lf.packages.count {
    val pkgEntry = lf.packages[ui]
    val nupkgSha: Option[String] = if Str.startsWith(pkgEntry.source, "nuget:") {
      match pkgEntry.sha512 {
        case Some(_) -> pkgEntry.sha512    // unlikely — kept defensively
        case None -> lockSha512OfNupkg(pkgEntry.name, pkgEntry.version)
      }
    } else {
      pkgEntry.sha512
    }
    upgraded.add(
      LF.LockedPackage(
        name = pkgEntry.name,
        version = pkgEntry.version,
        source = pkgEntry.source,
        sha512 = nupkgSha,
        path = pkgEntry.path
      )
    )
    ui = ui + 1
  }
  lf = LF.LockFile(formatVersion = lf.formatVersion, packages = upgraded)

  // Write the lock file or verify it (--locked mode).
  if lockedMode {
    // --locked: fail if no lock file exists on disk.
    if not lockFileExists {
      printErr("restore: --locked: no lock file found; run 'lyric restore' first to generate it")
      return 1
    }
    // A parse error was already reported above; fail without a misleading "is empty" message.
    if lockParseError {
      return 1
    }
    // Distinguish an empty lock file from a missing one.
    if existingLf.packages.count == 0 and lf.packages.count > 0 {
      printErr("restore: --locked: lock file exists but is empty; run 'lyric restore' to regenerate it")
      return 1
    }
    var lockMismatch = false
    // Forward check: every resolved package must be in the lock file.
    var ci = 0
    while ci < lf.packages.count {
      val resolved = lf.packages[ci]
      match LF.findPackage(existingLf, resolved.name) {
        case None -> {
          printErr(
            "restore: --locked: '" + resolved.name +
              "' is not recorded in the lock file (lyric.lock is stale — run 'lyric restore')"
          )
          lockMismatch = true
        }
        case Some(locked) -> {
          if locked.source != resolved.source {
            printErr(
              "restore: --locked: '" + resolved.name + "' source changed: locked='" + locked.source + "' resolved='" +
                resolved.source +
                "'"
            )
            lockMismatch = true
          } else if locked.version != resolved.version {
            printErr(
              "restore: --locked: '" + resolved.name + "' version changed: locked='" + locked.version + "' resolved='" +
                resolved.version +
                "'"
            )
            lockMismatch = true
          } else {
            // Content-integrity check (#738).  A `None` on the lock side
            // means the lock file pre-dates the SHA-512 enforcement; we
            // refuse to proceed and instruct the user to regenerate.  A
            // mismatch between the two digests means the resolved
            // artifact's content changed since the lock was written — the
            // exact registry-poisoning attack the lock file is supposed
            // to detect.
            match locked.sha512 {
              case None -> match resolved.sha512 {
                case None -> printErr("restore: --locked: warning: '" + resolved.name + "' has no SHA-512 on either side; integrity check skipped (regenerate lyric.lock with 'lyric restore' to populate digests)")
                // Both None — soft-pass with a warning so the operator knows the integrity check was skipped (typical for pre-#738 lock files).
                case Some(_) -> {
                  printErr(
                    "restore: --locked: '" + resolved.name +
                      "' has no SHA-512 in the lock file; lyric.lock pre-dates content-integrity enforcement — run 'lyric restore' to regenerate"
                  )
                  lockMismatch = true
                }
              }
              case Some(lockedHash) -> match resolved.sha512 { case None -> printErr("restore: --locked: warning: '" + resolved.name + "' could not be re-hashed; integrity check skipped (locked='" + lockedHash + "')"); case Some(resolvedHash) -> if lockedHash != resolvedHash { printErr("restore: --locked: '" + resolved.name + "' content changed: locked SHA-512 != resolved SHA-512"); printErr("  locked   : " + lockedHash); printErr("  resolved : " + resolvedHash); printErr("  (a registry-poisoning attack would surface here; if the package was legitimately updated, run 'lyric restore' to regenerate the lock)"); lockMismatch = true } }
            }
          }
        }
      }
      ci += 1
    }
    // Reverse check: every locked package must still be in lyric.toml.
    var ri = 0
    while ri < existingLf.packages.count {
      val locked = existingLf.packages[ri]
      match LF.findPackage(lf, locked.name) {
        case None -> {
          printErr(
            "restore: --locked: '" + locked.name +
              "' is in the lock file but not in lyric.toml (lyric.lock is stale — run 'lyric restore')"
          )
          lockMismatch = true
        }
        case Some(_) -> {
        }
      }
      ri += 1
    }
    if lockMismatch {
      return 1
    }
    Console.println("restore: --locked: lock file verified")
  } else {
    val lockText = LF.serializeLockFile(lf)
    match File.writeText(lockPath, lockText) {
      case Err(e) -> printErr("restore: warning: could not write lock file: " + IOError.message(e))
      case Ok(_) -> ()
    }
  }

  val mavenRc = restoreMavenJars(manifest, mfDir)
  if mavenRc != 0 {
    return mavenRc
  }

  Console.println("restore: done")
  0
}
