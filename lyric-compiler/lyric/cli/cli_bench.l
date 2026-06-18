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
// Run bench synthesis and execution for a single source file with pre-read source.
func runBenchOnSource(
  sourcePath: in String,
  source: in String,
  runsArg: in Int,
  warmupArg: in Int,
  filterArg: in String,
  targetJvm: in Bool,
): Int {
  val stem = stemOf(Path.basename(sourcePath), 2)
  val benchExt = if targetJvm { ".jar" } else { ".dll" }
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

      val benchTarget: CompileTarget = if targetJvm { Jvm } else { Dotnet }
      val req = EmitRequest(
        source = rewritten,
        assemblyName = stem,
        outputPath = outPath,
        target = benchTarget,
        packageVersion = "",
        buildKind = "lib"
      )
      val result = Emitter.emit(req)
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
      if targetJvm {
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
      } else {
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

func cmdBench(argv: in slice[String]): Int {
  var runsArg = 100
  var warmupArg = 5
  var filterArg = ""
  var manifestArg: Option[String] = None
  var targetJvm = false
  val positional: List[String] = newList()

  var i = 1
  while i < argv.length {
    val arg = argv[i]
    if arg == "--runs" {
      if i + 1 < argv.length {
        match parseOptInt(argv[i + 1]) {
          case Some(n) -> {
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
    } else if arg == "--target" {
      if i + 1 < argv.length {
        val t = argv[i + 1]
        if t == "jvm" {
          targetJvm = true
        } else if t == "dotnet" {
          targetJvm = false
        } else {
          printErr("bench: --target must be 'dotnet' or 'jvm'")
          return 1
        }
        i += 2
      } else {
        printErr("bench: --target requires an argument (dotnet|jvm)")
        return 1
      }
    } else {
      positional.add(arg)
      i += 1
    }
  }

  // Project-mode: no explicit source file — discover or use --manifest.
  // Scans all [project.packages] source files for @bench_module and runs each.
  if positional.count == 0 {
    val mfPath = match discoverManifest(manifestArg) {
      case Some(p) -> p
      case None -> {
        printErr("bench: missing source file and no lyric.toml found")
        return 1
      }
    }
    val (sourcePaths, hadFatal) = collectProjectSourcePaths(mfPath)
    if hadFatal {
      return 1
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
      val rc = runBenchOnSource(bPath, bSource, runsArg, warmupArg, filterArg, targetJvm)
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

  runBenchOnSource(sourcePath, source, runsArg, warmupArg, filterArg, targetJvm)
}
