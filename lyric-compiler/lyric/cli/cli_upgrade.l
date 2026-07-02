package Lyric.Cli

import Std.Core
import Std.Collections
import Std.Console as Console
import Std.File as File
import Std.Path as Path
import Std.Process as Process
import Std.Environment as Environment
import Std.Errors
import Std.ProcessCapture as ProcessCapture
import Std.Uuid as Uuid
import Std.Encoding as Encoding
import Std.Hash as Hash

// ─────────────────────────────────────────────────────────────────────────────
// §11i. Upgrade command — self-upgrade Lyric compiler
// ─────────────────────────────────────────────────────────────────────────────
pub func cmdUpgrade(argv: in slice[String]): Int {
  var isNuget = false
  var isGithub = false
  var targetVersion: Option[String] = None
  var targetDir: Option[String] = None
  var isDryRun = false

  var i = 1
  while i < argv.length {
    val arg = argv[i]
    if arg == "--nuget" or arg == "--dotnet-tool" {
      isNuget = true
      i += 1
    } else if arg == "--github" {
      isGithub = true
      i += 1
    } else if arg == "--version" {
      if i + 1 < argv.length {
        targetVersion = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("upgrade: --version requires a semver version string")
        return 1
      }
    } else if arg == "--dir" {
      if i + 1 < argv.length {
        targetDir = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("upgrade: --dir requires a directory path")
        return 1
      }
    } else if arg == "--dry-run" {
      isDryRun = true
      i += 1
    } else {
      printErr("upgrade: unrecognised argument '" + arg + "'")
      printUpgradeUsage()
      return 1
    }
  }

  // Conflict checks
  if isNuget and isGithub {
    printErr("upgrade: cannot specify both --nuget/--dotnet-tool and --github")
    return 1
  }

  val appBase = Environment.appBaseDirectory()

  // Auto-detect if not specified
  var useNuget = isNuget
  var useGithub = isGithub
  if not useNuget and not useGithub {
    // Detect .NET Tool via path containing ".store", "dotnet-tools", or ".dotnet"
    if containsSubstr(appBase, ".store") or containsSubstr(appBase, "dotnet-tools") or containsSubstr(appBase, ".dotnet") {
      useNuget = true
    } else {
      useGithub = true
    }
  }

  if useNuget {
    match targetDir {
      case Some(_) -> {
        printErr("upgrade: --dir option is only supported when upgrading via GitHub Releases (non-dotnet-tool)")
        return 1
      }
      case None -> ()
    }
    return runNugetUpgrade(targetVersion, isDryRun)
  } else {
    // No `--version` required here: `runGithubUpgrade` resolves an omitted
    // version to the latest published GitHub release (#4589) — a bare
    // `lyric upgrade` tracks the latest stable release, matching the
    // documented behavior in book/chapters/01-getting-started.md, rather
    // than requiring the caller to already know the current version.
    val installDir = match targetDir { case Some(d) -> d; case None -> appBase }
    return runGithubUpgrade(installDir, targetVersion, isDryRun)
  }
}

func containsSubstr(s: in String, needle: in String): Bool {
  s.indexOf(needle) >= 0
}

func printUpgradeUsage(): Unit {
  printErr("Usage: lyric upgrade [--nuget | --dotnet-tool] [--github] [--version <version>] [--dir <dir>] [--dry-run]")
}

func runNugetUpgrade(version: in Option[String], isDryRun: in Bool): Int {
  val args: List[String] = newList()
  args.add("tool")
  args.add("update")
  args.add("-g")
  args.add("lyric")

  match version {
    case Some(v) -> {
      args.add("--version")
      args.add(v)
    }
    case None -> ()
  }

  val cmdStr = "dotnet " + Process.buildArgString(args)
  if isDryRun {
    Console.println("dry-run: would run: " + cmdStr)
    return 0
  }

  Console.println("Upgrading Lyric .NET Tool: " + cmdStr)
  match Process.run("dotnet", args) {
    case Ok(code) -> code
    case Err(e) -> {
      printErr("upgrade: failed to execute dotnet: " + IOError.message(e))
      1
    }
  }
}

// Strip a single leading 'v'/'V' from a version-like string, e.g. the
// `tag_name` GitHub attaches to a release ("v0.4.6") into the bare semver
// form ("0.4.6") that `--version` and the install script expect (matching
// what a caller would type via `lyric upgrade --version 0.4.6`).
func stripLeadingV(v: in String): String {
  if v.length > 0 and (v[0] == 'v' or v[0] == 'V') {
    v.substring(1)
  } else {
    v
  }
}

// Extracts the `tag_name` field's string value from a GitHub Releases API
// JSON response body (the payload of GET /repos/<owner>/<repo>/releases/latest).
// Returns None when the field is absent or malformed.
//
// `.indexOf` only has a 1-arg (no start-offset) intrinsic overload, so each
// subsequent occurrence is located by re-scanning a tail substring and
// re-offsetting the result — the same idiom `cli_version.l`'s
// `replaceVersionInToml` uses for the same reason.
func extractTagNameFromReleaseJson(json: in String): Option[String] {
  val key = "\"tag_name\""
  val keyPos = json.indexOf(key)
  if keyPos < 0 {
    return None
  }
  val afterKey = json.substring(keyPos + key.length)
  val colonRel = afterKey.indexOf(":")
  if colonRel < 0 {
    return None
  }
  val afterColon = afterKey.substring(colonRel + 1)
  val openRel = afterColon.indexOf("\"")
  if openRel < 0 {
    return None
  }
  val afterOpen = afterColon.substring(openRel + 1)
  val closeRel = afterOpen.indexOf("\"")
  if closeRel < 0 {
    return None
  }
  val tag = afterOpen.substring(0, closeRel)
  if tag.length == 0 {
    None
  } else {
    Some(value = tag)
  }
}

// Query the GitHub Releases API for the latest published release's tag
// name.  Used as the default version for `lyric upgrade` on the GitHub
// Releases channel when no `--version` is given, so an unqualified upgrade
// tracks the latest stable release rather than the `main` development
// branch tip (#4589).  None on any network failure or unparseable response
// — the caller must not silently fall back to `main` in that case.
func fetchLatestReleaseTag(): Option[String] {
  match downloadUrl("https://api.github.com/repos/nichobbs/lyric-lang/releases/latest") {
    case Some(body) -> extractTagNameFromReleaseJson(body)
    case None -> None
  }
}

func downloadUrl(url: in String): Option[String] {
  // Try curl
  val curlArgs: List[String] = newList()
  curlArgs.add("-fsSL")
  curlArgs.add(url)

  val curlRes = ProcessCapture.runCaptureWithDiagnostics("curl", curlArgs, "")
  if curlRes.exitCode == 0 and not curlRes.timedOut {
    return Some(value = curlRes.stdout)
  }

  // Try wget
  val wgetArgs: List[String] = newList()
  wgetArgs.add("-q")
  wgetArgs.add("-O")
  wgetArgs.add("-")
  wgetArgs.add(url)

  val wgetRes = ProcessCapture.runCaptureWithDiagnostics("wget", wgetArgs, "")
  if wgetRes.exitCode == 0 and not wgetRes.timedOut {
    return Some(value = wgetRes.stdout)
  }

  None
}

func runGithubUpgrade(installDir: in String, versionArg: in Option[String], isDryRun: in Bool): Int {
  // Resolve an omitted `--version` to the latest published GitHub release
  // (#4589) instead of defaulting to the `main` branch tip, which is not
  // guaranteed stable.  This runs for both the dry-run and real paths so a
  // dry-run preview reports the version that would actually be installed.
  val version = match versionArg {
    case Some(v) -> Some(value = v)
    case None -> match fetchLatestReleaseTag() { case Some(tag) -> Some(value = stripLeadingV(tag)); case None -> None }
  }
  match version {
    case Some(_) -> ()
    case None -> {
      printErr(
        "upgrade: could not determine the latest release from GitHub (network error or API rate limit) — " +
          "pass --version <version> explicitly, or see https://github.com/nichobbs/lyric-lang/releases"
      )
      return 1
    }
  }

  val ref = match version {
    case Some(v) -> {
      if v.startsWith("v") then v else "v" + v
    }
    case None -> "main"  // unreachable: the None case above already returned.
  }
  val scriptUrl = "https://raw.githubusercontent.com/nichobbs/lyric-lang/" + ref + "/scripts/install.sh"

  // `--no-path` always applies here: this is an in-place upgrade of an
  // already-installed binary (the caller's PATH already resolves it), not a
  // first-time install, so re-running install.sh's shell-startup-file PATH
  // wiring would be redundant.  Surfaced explicitly (#4611) since the
  // installer's own output gives no indication that PATH is left untouched
  // — this matters most for `--dir <other-dir>`, where a user might
  // otherwise expect their shell to pick up the new location automatically.
  Console.println(
    "Note: shell PATH entries will not be modified; the binary at " + installDir + " is updated in place."
  )

  if isDryRun {
    Console.println("dry-run: would fetch install.sh from: " + scriptUrl)
    val printArgs: List[String] = newList()
    printArgs.add("--dir")
    printArgs.add(installDir)
    printArgs.add("--no-path")
    match version {
      case Some(v) -> {
        printArgs.add("--version")
        printArgs.add(v)
      }
      case None -> ()
    }
    Console.println(
      "dry-run: would write fetched script to temporary file and run: sh <tempFile> " + Process.buildArgString(printArgs)
    )
    return 0
  }

  Console.println("Retrieving installation script from GitHub (" + scriptUrl + ")...")
  var scriptContent = ""
  match downloadUrl(scriptUrl) {
    case Some(content) -> {
      scriptContent = content
    }
    case None -> {
      printErr("upgrade: failed to download the installation script from " + scriptUrl)
      return 1
    }
  }

  // Retrieve the checksum of the script
  val sha256Url = "https://raw.githubusercontent.com/nichobbs/lyric-lang/" + ref + "/scripts/install.sh.sha256"
  val sha256Option = downloadUrl(sha256Url)

  var expectedHash = ""
  match sha256Option {
    case Some(checksumContent) -> {
      val trimmed = checksumContent.trim()
      if trimmed.length >= 64 {
        expectedHash = trimmed.substring(0, 64).toUpper()
      } else {
        printErr("upgrade: downloaded checksum file is malformed (too short)")
        return 1
      }
    }
    case None -> {
      printErr("upgrade: failed to download the installation script checksum file from " + sha256Url)
      return 1
    }
  }

  // Threat model (#4603): `install.sh` and `install.sh.sha256` are both
  // fetched from this same repository at the same ref, so this comparison
  // only guards against in-transit corruption and CDN truncation — HTTPS
  // already covers the former.  It does NOT provide supply-chain integrity:
  // an attacker who can modify the repository (compromised maintainer
  // account or CI/CD token) can update both files together and this check
  // will pass.  Real supply-chain integrity needs an out-of-band signature
  // (e.g. a GPG key pinned into the binary at build time, or Sigstore) —
  // tracked as a follow-up; not implemented here.
  //
  // `scriptContent` is the String `downloadUrl` decoded from curl/wget's
  // captured stdout bytes (UTF-8, via `Std.ProcessCapture`'s internal
  // MemoryStream + StreamReader drain — see process_capture_host.l).
  // Re-encoding it here to hash is therefore hashing a decode/re-encode
  // round trip of the downloaded bytes, not the raw bytes themselves
  // (#4614). For a well-formed UTF-8 file with no byte-order mark this
  // round trip is lossless, which holds for `scripts/install.sh` today,
  // but the check has no way to detect a future violation of that
  // assumption (e.g. CRLF normalization on a different capture backend).
  // A byte-exact fix needs a raw-bytes capture variant on
  // `Std.ProcessCapture` (or a dedicated byte-returning download helper);
  // that's a stdlib-boundary change outside `Lyric.Cli`.
  val scriptBytes = Encoding.encodeUtf8(scriptContent)
  val actualHash = Hash.sha256OfBytes(scriptBytes).toUpper()
  if actualHash != expectedHash {
    printErr("upgrade: installation script hash mismatch (does not match install.sh.sha256) — aborting")
    printErr("Expected SHA-256: " + expectedHash)
    printErr("Actual SHA-256:   " + actualHash)
    return 1
  }

  // Create temporary directory path with unique UUID suffix to prevent symlink/TOCTOU attacks
  val tempDir = Environment.getVarOrDefault("TMPDIR", Environment.getVarOrDefault("TEMP", "/tmp"))
  val uuid = Uuid.uuidToString(Uuid.newUuid())
  val tempFile = Path.join(tempDir, "lyric-install-" + uuid + ".sh")

  match File.writeText(tempFile, scriptContent) {
    case Ok(_) -> ()
    case Err(e) -> {
      printErr("upgrade: failed to write temporary installation script to " + tempFile + ": " + IOError.message(e))
      return 1
    }
  }

  val shArgs: List[String] = newList()
  shArgs.add(tempFile)
  shArgs.add("--dir")
  shArgs.add(installDir)
  shArgs.add("--no-path")

  match version {
    case Some(v) -> {
      shArgs.add("--version")
      shArgs.add(v)
    }
    case None -> ()
  }

  Console.println("Executing installation script...")
  val code = match Process.run("sh", shArgs) {
    case Ok(c) -> c
    case Err(e) -> {
      printErr("upgrade: failed to execute sh " + tempFile + ": " + IOError.message(e))
      1
    }
  }

  // Cleanup
  match File.deleteFile(tempFile) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  code
}
