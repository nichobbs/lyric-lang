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
    val installDir = match targetDir {
      case Some(d) -> d
      case None -> appBase
    }
    return runGithubUpgrade(installDir, targetVersion, isDryRun)
  }
}

func containsSubstr(s: in String, needle: in String): Bool {
  match Str.indexOf(s, needle) {
    case Some(_) -> true
    case None -> false
  }
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

func runGithubUpgrade(installDir: in String, version: in Option[String], isDryRun: in Bool): Int {
  val ref = match version {
    case Some(v) -> {
      if Str.startsWith(v, "v") then v else "v" + v
    }
    case None -> "main"
  }
  val scriptUrl = "https://raw.githubusercontent.com/nichobbs/lyric-lang/" + ref + "/scripts/install.sh"

  // Download the install.sh script
  val curlArgs: List[String] = newList()
  curlArgs.add("-fsSL")
  curlArgs.add(scriptUrl)

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
  var scriptContent = ProcessCapture.runCapture("curl", curlArgs, "")
  if Str.isEmpty(scriptContent) {
    // Try wget
    val wgetArgs: List[String] = newList()
    wgetArgs.add("-q")
    wgetArgs.add("-O")
    wgetArgs.add("-")
    wgetArgs.add(scriptUrl)
    scriptContent = ProcessCapture.runCapture("wget", wgetArgs, "")
  }

  if Str.isEmpty(scriptContent) {
    printErr("upgrade: failed to download the installation script (curl and wget failed)")
    return 1
  }

  // Verify downloaded script hash matches expected stable install.sh hash only for main channel
  if ref == "main" {
    val expectedHash = "675DF2DAAA3BD3D0B86F6E3345099CFADA9FDA3BCD49EAC97358CFFB0EF7FD27"
    val scriptBytes = Encoding.encodeUtf8(scriptContent)
    val actualHash = Hash.sha256OfBytes(scriptBytes)
    if actualHash != expectedHash {
      printErr("upgrade: installation script integrity check failed!")
      printErr("Expected SHA-256: " + expectedHash)
      printErr("Actual SHA-256:   " + actualHash)
      return 1
    }
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

