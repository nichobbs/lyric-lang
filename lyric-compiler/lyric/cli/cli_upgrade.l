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
    if not isDryRun and isNone(targetVersion) {
      printErr("upgrade: --version <version> is required when upgrading via GitHub Releases")
      return 1
    }
    val installDir = match targetDir {
      case Some(d) -> d
      case None -> appBase
    }
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

func runGithubUpgrade(installDir: in String, version: in Option[String], isDryRun: in Bool): Int {
  val ref = match version {
    case Some(v) -> {
      if v.startsWith("v") then v else "v" + v
    }
    case None -> "main"
  }
  val scriptUrl = "https://raw.githubusercontent.com/nichobbs/lyric-lang/" + ref + "/scripts/install.sh"

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
    Console.println("dry-run: would run fetched script with arguments: sh -s -- " + Process.buildArgString(printArgs))
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

  val scriptBytes = Encoding.encodeUtf8(scriptContent)
  val actualHash = Hash.sha256OfBytes(scriptBytes)
  if actualHash != expectedHash {
    printErr("upgrade: installation script integrity check failed!")
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

