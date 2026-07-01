package Lyric.Cli

import Std.Core
import Std.Collections
import Std.Console as Console
import Std.File as File
import Std.Path as Path
import Std.Environment as Environment
import Std.Errors
import Std.String as Str
import Lyric.Emitter as Emitter
import Lyric.Lexer
import Lyric.Discovery as Disc
import Lyric.Lsp as Lsp
import Lyric.CliSuggest as Suggest

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

  // Internal (D111): emit the whole compiler-package import closure of a driver
  // into a SINGLE `Lyric.Compiler.dll` bundle via the self-hosted emitter.
  // `--internal-compiler-bundle-build <entry.l> <outPath>`.  Not user-facing;
  // produces the single-assembly compiler the self-tests link (sidestepping the
  // per-package cross-package emission corruption, docs/41 §R7).
  if cmd == "--internal-compiler-bundle-build" {
    if argv.length < 3 {
      printErr("usage: lyric --internal-compiler-bundle-build <entry.l> <outPath>")
      return 1
    }
    val entryPath = argv[1]
    val outPath = argv[2]
    match File.readText(entryPath) {
      case Err(e) -> {
        printErr("compiler-bundle: cannot read " + entryPath + ": " + IOError.message(e))
        return 1
      }
      case Ok(entrySrc) -> {
        val res = Emitter.emitCompilerBundle(entrySrc, outPath, Dotnet)
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
            Console.println("compiler bundle emitted to " + outPath)
            return 0
          }
          case None -> {
            printErr("compiler-bundle: emit failed")
            return 1
          }
        }
      }
    }
  }

  // Internal: compile a project from a spec file.
  // `--internal-project-build <specPath> -o <outputPath> --target <target>`
  if cmd == "--internal-project-build" {
    if argv.length < 6 {
      printErr("usage: lyric --internal-project-build <specPath> -o <outputPath> --target <target>")
      return 1
    }
    val specPath = argv[1]
    val outPath = argv[3]
    val targetStr = argv[5]
    val tgt = if targetStr == "jvm" { Jvm } else { Dotnet }

    match File.readText(specPath) {
      case Err(e) -> {
        printErr("project-build: cannot read spec " + specPath + ": " + IOError.message(e))
        return 1
      }
      case Ok(specContent) -> {
        val lines = Str.split(specContent, "\n")
        val pkgs: List[Emitter.ProjectPackage] = newList()
        val restoredDlls: List[String] = newList()
        val activeFeatures: List[String] = newList()
        val declaredFeatures: List[String] = newList()
        val nugetAssemblyPaths: List[String] = newList()

        var li = 0
        while li < lines.length {
          val line = Str.trim(lines[li])
          if line.length > 0 {
            val parts = Str.split(line, "\t")
            if parts.length >= 2 {
              val tag = parts[0]
              if tag == "DEP" {
                var reassembled = parts[1]
                var pi2 = 2
                while pi2 < parts.length {
                  reassembled = reassembled + "\t" + parts[pi2]
                  pi2 += 1
                }
                restoredDlls.add(reassembled)
              } else if tag == "FEATURE" {
                activeFeatures.add(parts[1])
              } else if tag == "DECLARED" {
                declaredFeatures.add(parts[1])
              } else if tag == "NUGET" {
                nugetAssemblyPaths.add(parts[1])
              } else {
                val pkgName = parts[0]
                val sources: List[String] = newList()
                var si = 1
                while si < parts.length {
                  val srcPath = parts[si]
                  match File.readText(srcPath) {
                    case Ok(srcText) -> sources.add(srcText)
                    case Err(e) -> {
                      printErr("project-build: cannot read source " + srcPath + ": " + IOError.message(e))
                      return 1
                    }
                  }
                  si += 1
                }
                pkgs.add(Emitter.ProjectPackage(name = pkgName, sources = sources))
              }
            }
          }
          li += 1
        }

        val stem = stemOf(Path.basename(outPath), 4)  // strip ".dll"

        val req = Emitter.EmitProjectRequest(
          packages = pkgs,
          assemblyName = stem,
          outputPath = outPath,
          target = tgt,
          restoredDllPaths = restoredDlls,
          activeFeatures = activeFeatures,
          declaredFeatures = declaredFeatures,
          packageVersion = "",
          depTemplateSrcs = newList(),
          nugetAssemblyPaths = nugetAssemblyPaths
        )

        val result = Emitter.emitProject(req)
        var hadError = false
        for d in result.diagnostics.toArray() {
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
        match result.outputPath {
          case Some(_) -> return 0
          case None -> {
            printErr("project-build: emit failed")
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

  // `lyric version` reads/writes lyric.toml and has no dependency on
  // Lyric.Stdlib.dll, so it must not be blocked by a strict SDK version
  // mismatch.  Dispatch it before the SDK check, alongside --version/--help.
  if cmd == "version" {
    return cmdVersion(argv)
  }

  // Check that the SDK (Lyric.Stdlib.dll) was built by this same compiler
  // version.  A mismatch is a warning by default; LYRIC_STRICT_SDK_VERSION=1
  // makes it a hard error (exit 1).
  val sdkCheck = checkSdkVersion()
  if sdkCheck != 0 {
    return sdkCheck
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

  if cmd == "upgrade" {
    return cmdUpgrade(argv)
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
