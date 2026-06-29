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
import Lyric.Emitter as Emitter
import Lyric.Discovery as Disc

// ─────────────────────────────────────────────────────────────────────────────
// §11f. Check command — type-check without producing a usable output artifact
// ─────────────────────────────────────────────────────────────────────────────
func cmdCheck(argv: in slice[String]): Int {
  var manifestArg: Option[String] = None
  var targetJvm = false
  val positional: List[String] = newList()

  var i = 1
  while i < argv.length {
    val arg = argv[i]
    if arg == "--manifest" {
      if i + 1 < argv.length {
        manifestArg = Some(value = argv[i + 1])
        i += 2
      } else {
        printErr("check: --manifest requires a path")
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
          printErr("check: --target must be 'dotnet' or 'jvm'")
          return 1
        }
        i += 2
      } else {
        printErr("check: --target requires an argument (dotnet|jvm)")
        return 1
      }
    } else {
      positional.add(arg)
      i += 1
    }
  }

  val checkTarget: CompileTarget = if targetJvm { Jvm } else { Dotnet }
  val checkExt = if targetJvm { ".jar" } else { ".dll" }

  // Project-mode: type-check all packages without producing a usable bin/ artifact.
  if positional.count == 0 {
    val mfPath = match discoverManifest(manifestArg) {
      case Some(p) -> p
      case None -> {
        printErr("check: missing source file and no lyric.toml found")
        return 1
      }
    }
    val checkOutDir = Path.join(Path.dirname(mfPath), ".lyric-check")
    val manifest = match File.readText(mfPath) {
      case Ok(t) -> match Mf.parseManifest(t, mfPath) { case Ok(m) -> m; case Err(e) -> { printErr("check: " + ManifestError.message(e)); return 1 } }
      case Err(e) -> {
        printErr("check: " + IOError.message(e))
        return 1
      }
    }
    val proj = match manifest.project {
      case Some(p) -> p
      case None -> {
        printErr("check: " + mfPath + " has no [project] section")
        return 1
      }
    }
    val asmName = match proj.outputAssembly { case Some(s) -> stemOf(s, 4); case None -> proj.name }
    val checkOut = Path.join(checkOutDir, asmName + checkExt)
    return buildProject(mfPath, Some(value = checkOut), checkTarget, newList(), false, false, true, None)
  }

  // Single-file mode: type-check without writing a permanent artifact.
  var anyFailed = false
  var fi = 0
  while fi < positional.count {
    val sourcePath = positional[fi]
    fi += 1
    val source = match File.readText(sourcePath) {
      case Ok(text) -> text
      case Err(e) -> {
        printErr("check: " + IOError.message(e))
        anyFailed = true
        continue
      }
    }

    val stem = stemOf(Path.basename(sourcePath), 2)
    val outPath = Path.join(Path.join(Path.dirname(sourcePath), ".lyric-check"), stem + checkExt)

    match File.createDir(Path.dirname(outPath)) {
      case Ok(_) -> ()
      case Err(_) -> ()
    }

    val req = EmitRequest(
      source = source,
      assemblyName = stem,
      outputPath = outPath,
      target = checkTarget,
      packageVersion = ""
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
      anyFailed = true
      continue
    }
    match result.outputPath {
      case None -> {
        printErr("check: " + sourcePath + ": build failed")
        anyFailed = true
        continue
      }
      case Some(_) -> ()
    }
    Console.println(sourcePath + ": ok")
  }

  if anyFailed {
    1
  } else {
    0
  }
}
