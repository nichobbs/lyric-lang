package Lyric.Cli

import Std.Core
import Std.Collections
import Std.Console as Console
import Std.File as File
import Std.Path as Path
import Std.Environment as Environment
import Std.Errors
import Lyric.Manifest as Mf
import Lyric.Lexer
import Lyric.Workspace as Ws
import Lyric.Lockfile as LF
import Lyric.Discovery as Disc

// ─────────────────────────────────────────────────────────────────────────────
// §11g. Update command — re-resolve all deps and rewrite lyric.lock
// ─────────────────────────────────────────────────────────────────────────────
func cmdUpdate(argv: in slice[String]): Int {
  var manifestArg: Option[String] = None

  var i = 1
  while i < argv.length {
    val arg = argv[i]
    if arg == "--manifest" {
      if i + 1 < argv.length {
        manifestArg = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("update: --manifest requires a path")
        return 1
      }
    } else {
      printErr("update: unrecognised argument '" + arg + "'")
      return 1
    }
  }

  val mfPath = match discoverManifest(manifestArg) {
    case Some(p) -> p
    case None -> {
      printErr("update: no lyric.toml found in this directory or any parent")
      return 1
    }
  }

  val mfDir = Path.dirname(mfPath)

  val wsCtx: Option[WorkspaceContext] = Ws.findWorkspaceRoot(mfDir)
  val lockPath = match wsCtx {
    case Some(ctx) -> Path.join(ctx.rootDir, "lyric.lock")
    case None -> Path.join(mfDir, "lyric.lock")
  }

  // Delete the existing lock file so restore performs a full re-resolution
  // rather than updating incrementally (i.e. picking up dep removals too).
  if File.fileExists(lockPath) {
    match File.deleteFile(lockPath) {
      case Ok(_) -> Console.println("update: removed " + lockPath)
      case Err(e) -> {
        printErr("update: could not remove " + lockPath + ": " + IOError.message(e))
        return 1
      }
    }
  }

  runRestore(mfPath, false)
}

// ─────────────────────────────────────────────────────────────────────────────
// §11h. Deps command — print the resolved dependency tree from lyric.lock
// ─────────────────────────────────────────────────────────────────────────────
func cmdDeps(argv: in slice[String]): Int {
  var manifestArg: Option[String] = None

  var i = 1
  while i < argv.length {
    val arg = argv[i]
    if arg == "--manifest" {
      if i + 1 < argv.length {
        manifestArg = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("deps: --manifest requires a path")
        return 1
      }
    } else {
      printErr("deps: unrecognised argument '" + arg + "'")
      return 1
    }
  }

  val mfPath = match discoverManifest(manifestArg) {
    case Some(p) -> p
    case None -> {
      printErr("deps: no lyric.toml found in this directory or any parent")
      return 1
    }
  }

  val mfDir = Path.dirname(mfPath)

  val wsCtx: Option[WorkspaceContext] = Ws.findWorkspaceRoot(mfDir)
  val lockPath = match wsCtx {
    case Some(ctx) -> Path.join(ctx.rootDir, "lyric.lock")
    case None -> Path.join(mfDir, "lyric.lock")
  }

  if not File.fileExists(lockPath) {
    printErr("deps: no lyric.lock found — run `lyric restore` first")
    return 1
  }

  val lockText = match File.readText(lockPath) {
    case Ok(t) -> t
    case Err(e) -> {
      printErr("deps: " + IOError.message(e))
      return 1
    }
  }

  val lf = match LF.parseLockFile(lockText) {
    case Ok(lf) -> lf
    case Err(e) -> {
      printErr("deps: failed to parse lyric.lock: " + e)
      return 1
    }
  }

  Console.println("dependencies (" + toString(lf.packages.count) + "):")
  var pi = 0
  while pi < lf.packages.count {
    val pkg = lf.packages[pi]
    pi += 1
    val versionStr = if pkg.version.length > 0 { " " + pkg.version } else { "" }
    Console.println("  " + pkg.name + versionStr + "  [" + pkg.source + "]")
  }
  0
}
