package Lyric.Cli

import Std.Core
import Std.Collections
import Std.Console as Console
import Std.File as File
import Std.Environment as Environment
import Std.Errors
import Lyric.Emitter as Emitter
import Lyric.Lexer
import Lyric.Discovery as Disc
import Lyric.Lsp as Lsp
import Lyric.CliSuggest as Suggest
import Lyric.Cli.Shared
import Lyric.Cli.Restore
import Lyric.Cli.Build
import Lyric.Cli.Quality
import Lyric.Cli.Test

// ─────────────────────────────────────────────────────────────────────────────
// §12. Entry point
// ─────────────────────────────────────────────────────────────────────────────
pub func main(argv: in slice[String]): Int {
  // Bare `lyric` builds the discovered project (the project-aware default).
  // Outside a project it is still a usage error, not a silent no-op.
  if argv.length == 0 {
    match Disc.findNearestManifest(Environment.currentDirectory()) {
      case Some(p) -> {
        // Forward the discovered path so cmdBuild doesn't walk the tree again.
        val buildArgv: List[String] = newList()
        buildArgv.add("build")
        buildArgv.add("--manifest")
        buildArgv.add(p)
        return cmdBuild(buildArgv.toArray())
      }
      case None -> {
        printUsage()
        return 1
      }
    }
  }

  val cmd = argv[0]

  // Internal (#2592 stage-2): emit a driver's transitive `Std.*` import closure
  // into per-package `Lyric.Stdlib.<X>.dll` assemblies via the self-hosted
  // emitter.  `--internal-perpackage-build <entry.l> <outDir> [--target jvm]`.
  // Not a user-facing command; used to produce the self-hosted stdlib layout.
  if cmd == "--internal-perpackage-build" {
    if argv.length < 3 {
      printErr("usage: lyric --internal-perpackage-build <entry.l> <outDir> [--target jvm]")
      return 1
    }
    val entryPath = argv[1]
    val outDir = argv[2]
    val tgt = if argv.length >= 5 and argv[3] == "--target" and argv[4] == "jvm" { Jvm } else { Dotnet }
    match File.readText(entryPath) {
      case Err(e) -> {
        printErr("perpackage: cannot read " + entryPath + ": " + IOError.message(e))
        return 1
      }
      case Ok(entrySrc) -> {
        val res = Emitter.emitPerPackageClosure(entrySrc, outDir, tgt)
        var hadError = false
        for d in res.diagnostics.toArray() {
          printDiag(d)
          match d.severity {
            case DiagError -> {
              hadError = true
            }
            case DiagWarning -> ()
          }
        }
        if hadError {
          return 1
        }
        match res.outputPath {
          case Some(_) -> {
            Console.println("per-package stdlib emitted to " + outDir)
            return 0
          }
          case None -> {
            printErr("perpackage: emit failed")
            return 1
          }
        }
      }
    }
  }

  if cmd == "--version" or cmd == "-v" {
    Console.println("lyric " + VERSION())
    return 0
  }

  if cmd == "--help" or cmd == "-h" or cmd == "help" {
    Console.println(usageText())
    return 0
  }

  if cmd == "build" {
    return cmdBuild(argv)
  }

  if cmd == "run" {
    return cmdRun(argv)
  }

  if cmd == "fmt" {
    return cmdFmt(argv)
  }

  if cmd == "lint" {
    return cmdLint(argv)
  }

  if cmd == "prove" {
    return cmdProve(argv)
  }

  if cmd == "doc" {
    return cmdDoc(argv)
  }

  if cmd == "public-api-diff" {
    return cmdPublicApiDiff(argv)
  }

  if cmd == "restore" {
    return cmdRestore(argv)
  }

  if cmd == "add" {
    return cmdAdd(argv)
  }

  if cmd == "remove" {
    return cmdRemove(argv)
  }

  if cmd == "init" {
    return cmdInit(argv)
  }

  if cmd == "publish" {
    return cmdPublish(argv)
  }

  if cmd == "search" {
    return cmdSearch(argv)
  }

  if cmd == "repl" {
    return cmdRepl(argv)
  }

  if cmd == "test" {
    return cmdTest(argv)
  }

  if cmd == "bench" {
    return cmdBench(argv)
  }

  if cmd == "check" {
    return cmdCheck(argv)
  }

  if cmd == "clean" {
    return cmdClean(argv)
  }

  if cmd == "update" {
    return cmdUpdate(argv)
  }

  if cmd == "deps" {
    return cmdDeps(argv)
  }

  if cmd == "openapi" {
    return cmdOpenApi(argv)
  }

  if cmd == "lsp" {
    // Dispatch to the self-hosted LSP stdio loop in
    // `lyric-compiler/lyric/lsp.l`.  No CLI args are consumed —
    // the language server speaks the Language Server Protocol
    // over stdin/stdout per LSP §3.0.
    Lsp.lspRunLoop()
    return 0
  }

  printErr("unknown command: " + cmd)
  match Suggest.suggestCommand(cmd) {
    case Some(s) -> printErr("did you mean '" + s + "'?")
    case None -> ()
  }
  printUsage()
  1
}
