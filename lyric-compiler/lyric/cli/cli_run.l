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
import Std.Time as Time
import Lyric.Manifest as Mf
import Lyric.Lexer
import Lyric.Emitter as Emitter
import Lyric.AppHost as AppHost
import Lyric.Discovery as Disc

// Build a project and run its output artifact.
func runProjectOnce(mfPath: in String, userArgs: in List[String], target: in CompileTarget): Int {
  val mfText = match File.readText(mfPath) {
    case Ok(t) -> t
    case Err(e) -> {
      printErr("run: " + IOError.message(e))
      return 1
    }
  }
  val manifest = match Mf.parseManifest(mfText, mfPath) {
    case Ok(m) -> m
    case Err(e) -> {
      printErr("run: " + ManifestError.message(e))
      return 1
    }
  }
  val proj = match manifest.project {
    case None -> {
      printErr("run: " + mfPath + " has no [project] section")
      return 1
    }
    case Some(p) -> p
  }
  val mfDir = Path.dirname(mfPath)
  val buildRc = buildProject(mfPath, None, target, newList(), false, false, false, None)
  if buildRc != 0 {
    return buildRc
  }
  val buildKind = getBuildKind(manifest)
  val outPath = projectBinOutputPath(mfDir, proj, target, buildKind)
  if not File.fileExists(outPath) {
    printErr("run: project output not found after build: " + outPath)
    return 1
  }
  match target {
    case Native -> {
      printErr("run: --target native does not yet support manifest (multi-package) projects")
      return 1
    }
    case Jvm -> {
      val execArgs: List[String] = newList()
      execArgs.add("-jar")
      execArgs.add(outPath)
      for a in userArgs.toArray() {
        execArgs.add(a)
      }
      match Process.run("java", execArgs) {
        case Ok(code) -> code
        case Err(e) -> {
          printErr("run: failed to start java: " + IOError.message(e))
          1
        }
      }
    }
    case Dotnet -> {
      copyRuntimeDepsBeside(outPath, findCompiledLibDir())
      // For `kind = "exe"` builds, prefer the native apphost launcher emitted
      // beside the DLL: run it directly with no `dotnet exec` prefix.
      val launcher = if buildKind == "exe" {
        match AppHost.launcherPathForDll(outPath) {
          case Some(p) -> if File.fileExists(p) { Some(value = p) } else { None }
          case None -> None
        }
      } else {
        None
      }
      match launcher {
        case Some(launcherPath) -> {
          match Process.run(launcherPath, userArgs) {
            case Ok(code) -> code
            case Err(e) -> {
              printErr("run: failed to start launcher: " + IOError.message(e))
              1
            }
          }
        }
        case None -> {
          // A `kind = "exe"` build should have a native launcher beside the
          // DLL; if it is missing (no apphost template on this host, or the
          // file was removed) we still run via `dotnet exec` so `lyric run`
          // keeps working, but say so rather than falling back silently.
          if buildKind == "exe" {
            printErr(
              "run: warning: no native launcher found for this 'kind = \"exe\"' build; " +
                "falling back to 'dotnet exec' (install a Microsoft.NETCore.App.Host.<rid> " +
                "runtime pack, or set DOTNET_ROOT to a .NET install that has one, so the " +
                "apphost template can be located)"
            )
          }
          val execArgs: List[String] = newList()
          execArgs.add("exec")
          execArgs.add(outPath)
          for a in userArgs.toArray() {
            execArgs.add(a)
          }
          match Process.run("dotnet", execArgs) {
            case Ok(code) -> code
            case Err(e) -> {
              printErr("run: failed to start dotnet: " + IOError.message(e))
              1
            }
          }
        }
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. Run command
// ─────────────────────────────────────────────────────────────────────────────
// ── --watch support (#1974) ──────────────────────────────────────────────────
//
// The watch loop runs in the CLI process (the .NET AOT binary), polling a set
// of source files and re-running the action when any of them changes.  Change
// detection fingerprints each file with sha512 (reused from lock integrity) so
// it needs no new file-metadata primitive; the only new stdlib primitive is the
// synchronous Std.Time.sleepMillis poll interval.  The loop runs until the user
// interrupts it (Ctrl-C).
val WATCH_POLL_MS: Int = 400

// The deferred action a watch loop re-runs on each detected change.
union WatchAction {
  case RunFile(sourcePath: String, userArgs: List[String], target: CompileTarget)
  case RunProj(mfPath: String, userArgs: List[String], target: CompileTarget)
  case BuildProj(mfPath: String, outArg: Option[String], target: CompileTarget, feats: List[String], noDef: Bool, allF: Bool, noRestore: Bool, pkgVer: Option[String])
  case BuildFile(sourcePath: String, outArg: String, target: CompileTarget, manifest: Option[String], nativeTriple: String, nativeOpt: String)
}

// Build the program once and execute it.  Target-aware: Dotnet runs via
// `dotnet exec`, Jvm runs via `java -jar`.  Extracted from cmdRun so the
// watch loop can re-run it.
func runOnce(sourcePath: in String, userArgs: in List[String], target: in CompileTarget): Int {
  val srcDir = Path.dirname(sourcePath)
  val stem = stemOf(Path.basename(sourcePath), 2)
  // var-mutation shape: a value-position match over CompileTarget
  // mis-lowers under the stage-0 emitter (see cmdRun's runTarget note).
  var outExt = ""
  match target {
    case Jvm -> {
      outExt = ".jar"
    }
    case Dotnet -> {
      outExt = ".dll"
    }
    case Native -> {
      outExt = ""
    }
  }
  val outPath = Path.join(Path.join(srcDir, ".lyric-run"), stem + outExt)

  val buildExit = buildOne(sourcePath, outPath, target, None)
  if buildExit != 0 {
    return buildExit
  }

  match target {
    case Jvm -> {
      val execArgs: List[String] = newList()
      execArgs.add("-jar")
      execArgs.add(outPath)
      for a in userArgs.toArray() {
        execArgs.add(a)
      }
      match Process.run("java", execArgs) {
        case Ok(code) -> code
        case Err(e) -> {
          printErr("run: failed to start java: " + IOError.message(e))
          1
        }
      }
    }
    case Dotnet -> {
      // Co-locate the fully-compiled stdlib runtime assemblies beside the output
      // so a program using real stdlib `pub func`s resolves them under `dotnet exec`.
      copyRuntimeDepsBeside(outPath, findCompiledLibDir())
      val execArgs: List[String] = newList()
      execArgs.add("exec")
      execArgs.add(outPath)
      for a in userArgs.toArray() {
        execArgs.add(a)
      }
      match Process.run("dotnet", execArgs) {
        case Ok(code) -> code
        case Err(e) -> {
          printErr("run: failed to start dotnet: " + IOError.message(e))
          1
        }
      }
    }
    case Native -> {
      // A native build IS the executable; run it directly.
      val execArgs: List[String] = newList()
      for a in userArgs.toArray() {
        execArgs.add(a)
      }
      match Process.run(outPath, execArgs) {
        case Ok(code) -> code
        case Err(e) -> {
          printErr("run: failed to start " + outPath + ": " + IOError.message(e))
          1
        }
      }
    }
  }
}

func runWatchAction(a: in WatchAction): Int {
  match a {
    case RunFile(sp, ua, t) -> runOnce(sp, ua, t)
    case RunProj(mp, ua, t) -> runProjectOnce(mp, ua, t)
    case BuildProj(mf, o, t, f, nd, af, nr, pv) -> buildProject(mf, o, t, f, nd, af, nr, pv)
    case BuildFile(sp, o, t, m, tr, op) -> buildOneNative(sp, o, t, m, tr, op)
  }
}

// A change-detection fingerprint over `files`: each file's sha512 (or "∅" when
// missing) joined together, so adding, removing, or editing any watched file
// flips the value.
func watchFingerprint(files: in List[String]): String {
  var fp = ""
  var i = 0
  while i < files.count {
    val f = files[i]
    val h = match Hash.sha512OfFile(f) { case Ok(x) -> x; case Err(_) -> "∅" }
    fp = fp + f + "=" + h + ";"
    i += 1
  }
  fp
}

// Run `action` once, then poll `files` and re-run on every change until the
// process is interrupted.  Never returns under normal use.
func watchLoop(files: in List[String], action: in WatchAction): Int {
  Console.println("watch: watching " + toString(files.count) + " file(s); press Ctrl-C to stop")
  // Snapshot the fingerprint BEFORE the initial run so any edit that occurs
  // during compilation is captured by the first poll and triggers a re-run.
  var fp = watchFingerprint(files)
  val initRc = runWatchAction(action)
  Console.println("watch: done (exit " + toString(initRc) + "); waiting for changes ...")
  while true {
    Time.sleepMillis(WATCH_POLL_MS)
    val cur = watchFingerprint(files)
    if cur != fp {
      fp = cur
      Console.println("")
      Console.println("watch: change detected — rerunning ...")
      val rc = runWatchAction(action)
      Console.println("watch: done (exit " + toString(rc) + "); waiting for changes ...")
    }
  }
  0
}

// The files a project `build --watch` should watch: the manifest plus every
// `[project.packages]` source path (resolved relative to the manifest dir).
func projectWatchFiles(mfPath: in String): List[String] {
  val files: List[String] = newList()
  files.add(mfPath)
  val mfDir = Path.dirname(mfPath)
  match File.readText(mfPath) {
    case Err(_) -> {
      Console.error("watch: could not read manifest '" + mfPath + "' — watching manifest file only")
    }
    case Ok(txt) -> match Mf.parseManifest(txt, mfPath) { case Err(_) -> { Console.error("watch: could not parse manifest '" + mfPath + "' — watching manifest file only") }; case Ok(m) -> match m.project { case None -> (); case Some(p) -> { var i = 0; while i < p.packages.count { val pkgEntry = p.packages[i]; if pkgEntry.paths.count > 0 { var fi = 0; while fi < pkgEntry.paths.count { files.add(Path.join(mfDir, pkgEntry.paths[fi])); fi += 1 } } else { files.add(Path.join(mfDir, pkgEntry.path)) }; i += 1 } } } }
  }
  files
}

func cmdRun(argv: in slice[String]): Int {
  var watch = false
  var sourcePath = ""
  var haveSource = false
  var manifestArg: Option[String] = None
  var targetArg: Option[String] = None
  val userArgs: List[String] = newList()

  var i = 1
  var pastSep = false
  while i < argv.length {
    val arg = argv[i]
    if pastSep {
      userArgs.add(arg)
      i += 1
    } else if arg == "--" {
      pastSep = true
      i += 1
    } else if arg == "--watch" {
      watch = true
      i += 1
    } else if arg == "--manifest" {
      if i + 1 < argv.length {
        manifestArg = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("run: --manifest requires a path")
        return 1
      }
    } else if arg == "--target" {
      if i + 1 < argv.length {
        targetArg = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("run: --target requires dotnet or jvm")
        return 1
      }
    } else if not haveSource {
      sourcePath = arg
      haveSource = true
      i += 1
    } else {
      userArgs.add(arg)
      i += 1
    }
  }

  // var-mutation shape: val/match/if with nested if mis-lowers under the stage-0 emitter.
  var runTarget: CompileTarget = Dotnet
  match targetArg {
    case None -> ()
    case Some(t) -> {
      if t == "jvm" {
        runTarget = Jvm
      } else if t == "native" {
        runTarget = Native
      } else if t == "dotnet" {
        runTarget = Dotnet
      } else {
        printErr("run: unknown target '" + t + "' — expected dotnet, jvm, or native")
        return 1
      }
    }
  }

  // Project-mode: no explicit source file — discover or use --manifest.
  if not haveSource {
    val mfPath = match discoverManifest(manifestArg) {
      case Some(p) -> p
      case None -> {
        printErr("run: missing source file and no lyric.toml found")
        printUsage()
        return 1
      }
    }
    if watch {
      return watchLoop(projectWatchFiles(mfPath), RunProj(mfPath = mfPath, userArgs = userArgs, target = runTarget))
    }
    return runProjectOnce(mfPath, userArgs, runTarget)
  }

  if not File.fileExists(sourcePath) {
    printErr("run: source file not found: " + sourcePath)
    return 1
  }

  if watch {
    val files: List[String] = newList()
    files.add(sourcePath)
    return watchLoop(files, RunFile(sourcePath = sourcePath, userArgs = userArgs, target = runTarget))
  }

  runOnce(sourcePath, userArgs, runTarget)
}
