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
import Std.Parse
import Lyric.Manifest as Mf
import Lyric.Lexer
import Lyric.Emitter as Emitter
import Lyric.BenchSynth as BenchSynth
import Lyric.Discovery as Disc

// ─────────────────────────────────────────────────────────────────────────────
// §11d. Bench command
// ─────────────────────────────────────────────────────────────────────────────
// The `--target native` build settings a bench uses: the manifest's
// `[native]` table merged with the `--triple`/`--opt` flags, as `lyric build`
// merges them (#8096).
pub record NativeBenchConfig {
  triple: String
  optLevel: String
  extraLibs: List[String]
}

// Resolves the native settings for a bench: a non-empty `--triple`/`--opt`
// wins over the manifest's `triple`/`opt_level`, and `extra_libs` comes from
// the manifest. A benchmark measures optimised code, so the level defaults to
// `-O2` (the release profile) when neither names one. A wasm32 triple is
// rejected: the benchmark runs on this machine.
pub func resolveNativeBenchConfig(
  manifestPath: in Option[String], cliTriple: in String, cliOpt: in String
): Result[NativeBenchConfig, String] {
  var triple = cliTriple
  var opt = cliOpt
  val libs: List[String] = newList()
  match resolveNativeConfig(manifestPath) {
    case Err(msg) -> return Err(error = msg)
    case Ok(ncOpt) -> match ncOpt {
      case Some(nc) -> {
        if triple == "" {
          triple = nc.triple
        }
        if opt == "" {
          opt = nc.optLevel
        }
        for lib in nc.extraLibs {
          libs.add(lib)
        }
      }
      case None -> ()
    }
  }
  if Str.startsWith(triple, "wasm32") {
    return Err(
      error = "bench: --target native runs the benchmark on this machine, so the triple cannot be '" + triple + "'"
    )
  }
  if opt == "" {
    opt = "2"
  }
  Ok(value = NativeBenchConfig(triple = triple, optLevel = opt, extraLibs = libs))
}

// Run bench synthesis and execution for a single source file with pre-read source.
func runBenchOnSource(
  sourcePath: in String,
  source: in String,
  runsArg: in Int,
  warmupArg: in Int,
  filterArg: in String,
  target: in Emitter.CompileTarget,
  nativeCfg: in NativeBenchConfig,
): Int {
  val stem = stemOf(Path.basename(sourcePath), 2)
  val benchExt = match target { case Emitter.Jvm -> ".jar"; case Emitter.Dotnet -> ".dll"; case Emitter.Native -> "" }
  val outPath = Path.join(Path.join(Path.dirname(sourcePath), ".lyric-bench"), stem + benchExt)

  match BenchSynth.synthesizeBench(source, runsArg, warmupArg, filterArg) {
    case NoBenchModule(span) -> {
      printErr(sourcePath + ":" + toString(span.startPos.line) + ": not a @bench_module — add @bench_module annotation")
      return 1
    }
    case BenchUserMainExists(span) -> {
      printErr(sourcePath + ":" + toString(span.startPos.line) + ": @bench_module cannot define func main()")
      return 1
    }
    case BenchParseFailures(diags) -> {
      for d in diags.toArray() {
        printDiag(d)
      }
      return 1
    }
    case BenchSynthesised(rewritten, benchCount) -> {
      Console.println(toString(benchCount) + " benchmark(s)")

      match File.createDir(Path.dirname(outPath)) {
        case Ok(_) -> ()
        case Err(_) -> ()
      }

      // Benchmarks measure release code: integer arithmetic wraps instead of
      // carrying a debug build's overflow checks (D163).
      val benchDefines: List[String] = newList()
      benchDefines.add("build_profile=release")
      val req = Emitter.EmitRequest(
        source = rewritten,
        assemblyName = stem,
        outputPath = outPath,
        target = target,
        packageVersion = "",
        defines = benchDefines,
        path = sourcePath,
        contractsEnabled = true
      )
      val result = match target {
        case Emitter.Native -> Emitter.emitNative(
          req,
          nativeCfg.triple,
          nativeCfg.optLevel,
          nativeCfg.extraLibs
        )
        case _ -> Emitter.emit(req)
      }
      var hadError = false
      for d in result.diagnostics.toArray() {
        match d.severity {
          case DiagError -> {
            hadError = true
          }
          case DiagWarning -> ()
        }
        printDiag(d)
      }
      if hadError {
        return 1
      }
      match result.outputPath {
        case None -> {
          printErr("bench: build failed")
          return 1
        }
        case Some(_) -> ()
      }
      match target {
        case Emitter.Jvm -> {
          val jvmArgs: List[String] = newList()
          jvmArgs.add("-jar")
          jvmArgs.add(outPath)
          match Process.run("java", jvmArgs) {
            case Ok(code) -> code
            case Err(e) -> {
              printErr("bench: failed to start java: " + IOError.message(e))
              1
            }
          }
        }
        case Emitter.Native -> {
          // The native build is the executable itself.
          val noArgs: List[String] = newList()
          match Process.run(outPath, noArgs) {
            case Ok(code) -> code
            case Err(e) -> {
              printErr("bench: failed to start " + outPath + ": " + IOError.message(e))
              1
            }
          }
        }
        case Emitter.Dotnet -> {
          // Harness imports Std.Time, so stdlib DLLs must be co-located beside the output (mirrors runOnce).
          copyRuntimeDepsBeside(outPath, findCompiledLibDir())
          writeRuntimeConfig(outPath)
          val execArgs: List[String] = newList()
          execArgs.add("exec")
          execArgs.add(outPath)
          match Process.run("dotnet", execArgs) {
            case Ok(code) -> code
            case Err(e) -> {
              printErr("bench: failed to start dotnet: " + IOError.message(e))
              1
            }
          }
        }
      }
    }
  }
}

func cmdBench(argv: in slice[String]): Int {
  var runsArg = 100
  var warmupArg = 5
  var filterArg = ""
  var manifestArg: Option[String] = None
  var target: Emitter.CompileTarget = Emitter.Dotnet
  var tripleArg = ""
  var optArg = ""
  val positional: List[String] = newList()

  var i = 1
  while i < argv.length {
    val arg = argv[i]
    if arg == "--runs" {
      if i + 1 < argv.length {
        match parseOptInt(argv[i + 1]) {
          case Some(n) -> {
            if n < 1 {
              printErr("bench: --runs must be at least 1, got " + toString(n))
              return 64
            }
            runsArg = n
            i += 2
          }
          case None -> {
            printErr("bench: --runs requires an integer")
            return 1
          }
        }
      } else {
        printErr("bench: --runs requires a value")
        return 1
      }
    } else if arg == "--warmup" {
      if i + 1 < argv.length {
        match parseOptInt(argv[i + 1]) {
          case Some(n) -> {
            if n < 0 {
              printErr("bench: --warmup must not be negative, got " + toString(n))
              return 64
            }
            warmupArg = n
            i += 2
          }
          case None -> {
            printErr("bench: --warmup requires an integer")
            return 1
          }
        }
      } else {
        printErr("bench: --warmup requires a value")
        return 1
      }
    } else if arg == "--filter" {
      if i + 1 < argv.length {
        filterArg = argv[i + 1]
        i += 2
      } else {
        printErr("bench: --filter requires a value")
        return 1
      }
    } else if arg == "--manifest" {
      if i + 1 < argv.length {
        manifestArg = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("bench: --manifest requires a path")
        return 1
      }
    } else if arg == "--triple" {
      if i + 1 < argv.length {
        tripleArg = argv[i + 1]
        i += 2
      } else {
        printErr("bench: --triple requires an argument (an LLVM target triple, e.g. x86_64-unknown-linux-gnu)")
        return 1
      }
    } else if arg == "--opt" {
      if i + 1 < argv.length {
        optArg = argv[i + 1]
        if not (optArg == "0" or optArg == "1" or optArg == "2" or optArg == "3" or optArg == "s") {
          printErr("bench: --opt must be 0, 1, 2, 3 or s, got '" + optArg + "'")
          return 64
        }
        i += 2
      } else {
        printErr("bench: --opt requires an argument (0, 1, 2, 3, or s)")
        return 1
      }
    } else if arg == "--target" {
      if i + 1 < argv.length {
        val t = argv[i + 1]
        if t == "jvm" {
          target = Emitter.Jvm
        } else if t == "dotnet" {
          target = Emitter.Dotnet
        } else if t == "native" {
          target = Emitter.Native
        } else {
          printErr("bench: --target must be 'dotnet', 'jvm' or 'native'")
          return 1
        }
        i += 2
      } else {
        printErr("bench: --target requires an argument (dotnet|jvm|native)")
        return 1
      }
    } else {
      positional.add(arg)
      i += 1
    }
  }

  var nativeCfg = NativeBenchConfig(triple = "", optLevel = "", extraLibs = newList())
  match target {
    case Emitter.Native -> match resolveNativeBenchConfig(manifestArg, tripleArg, optArg) {
      case Ok(cfg) -> {
        nativeCfg = cfg
      }
      case Err(msg) -> {
        printErr(msg)
        return 1
      }
    }
    case _ -> if tripleArg != "" or optArg != "" {
      printErr("bench: --triple and --opt apply only to --target native")
      return 64
    }
  }

  // Project-mode: no explicit source file — discover or use --manifest.
  // Scans all [project.packages] source files for @bench_module and runs each.
  if positional.count == 0 {
    val sourcePaths = match resolveProjectSources(manifestArg) {
      case ProjSourcesMissingManifest -> {
        printErr("bench: missing source file and no lyric.toml found")
        return 1
      }
      case ProjSourcesFatal -> return 1
      case ProjSourcesFound(_, paths) -> paths
    }
    val benchFiles: List[String] = newList()
    val benchSources: List[String] = newList()
    var anyFailed = false
    var pi = 0
    while pi < sourcePaths.count {
      val sp = sourcePaths[pi]
      pi += 1
      match File.readText(sp) {
        case Ok(source) -> {
          // Detect @bench_module by checking that some source line, stripped of
          // leading/trailing whitespace, is exactly "@bench_module".  This avoids
          // false-positives from the text appearing inside string literals or
          // comments that happen to contain the annotation.
          val lines = Str.split(source, "\n")
          var hasBench = false
          var li = 0
          while li < lines.length {
            if Str.trim(lines[li]) == "@bench_module" {
              hasBench = true
            }
            li += 1
          }
          if hasBench {
            benchFiles.add(sp)
            benchSources.add(source)
          }
        }
        case Err(e) -> {
          printErr("bench: cannot read '" + sp + "': " + IOError.message(e))
          anyFailed = true
        }
      }
    }
    if anyFailed {
      return 1
    }
    if benchFiles.count == 0 {
      printErr("bench: no @bench_module files found in project")
      return 1
    }
    var bi = 0
    while bi < benchFiles.count {
      val bPath = benchFiles[bi]
      val bSource = benchSources[bi]
      bi += 1
      Console.println("== bench: " + bPath)
      val rc = runBenchOnSource(bPath, bSource, runsArg, warmupArg, filterArg, target, nativeCfg)
      if rc != 0 {
        anyFailed = true
      }
    }
    if anyFailed {
      return 1
    }
    return 0
  }

  val sourcePath = positional[0]
  val source = match File.readText(sourcePath) {
    case Ok(text) -> text
    case Err(e) -> {
      printErr("bench: " + IOError.message(e))
      return 1
    }
  }

  runBenchOnSource(sourcePath, source, runsArg, warmupArg, filterArg, target, nativeCfg)
}
