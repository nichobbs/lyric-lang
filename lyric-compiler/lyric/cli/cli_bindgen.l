package Lyric.Cli

import Std.Core
import Std.Collections
import Std.Console as Console
import Std.File as File
import Std.String as Str
import Std.Process as Process
import Lyric.Bindgen as Bindgen
import Lyric.Fmt as Fmt

// ─────────────────────────────────────────────────────────────────────────────
// `lyric bindgen` (docs/67 §5.3, D190): C header -> `_kernel_native/` bindings.
// ─────────────────────────────────────────────────────────────────────────────
val bindgenUsage: String = "usage: lyric bindgen <header.h> --package <Name> --allow <file> [-o <out.l>] [--library <name>] [-I <dir>]... [--clang-arg <arg>]... [--triple <llvm-triple>] [--long-bits 32|64] [--cfg <predicate>] [--check]"

func argvHas(argv: in slice[String], flag: in String): Bool {
  for a in argv {
    if a == flag {
      return true
    }
  }
  false
}

func cmdBindgen(argv: in slice[String]): Int {
  var header = ""
  var packageName = ""
  var allowFile = ""
  var outPath = ""
  var library = ""
  var longBits = 64
  var pointerBits = 0
  var triple = ""
  var fileCfg = ""
  var check = false
  val clangArgs: List[String] = newList()
  var i = 1
  while i < argv.length {
    val arg = argv[i]
    if arg == "--package" or arg == "--allow" or arg == "-o" or arg == "--library" or arg == "-I" or arg == "--clang-arg" or arg == "--long-bits" or arg == "--triple" or arg == "--cfg" {
      if i + 1 >= argv.length {
        printErr("bindgen: " + arg + " requires a value")
        return 1
      }
      val value = argv[i + 1]
      i += 2
      if arg == "--package" {
        packageName = value
      } else if arg == "--allow" {
        allowFile = value
      } else if arg == "-o" {
        outPath = value
      } else if arg == "--library" {
        library = value
      } else if arg == "-I" {
        clangArgs.add("-I" + value)
      } else if arg == "--clang-arg" {
        clangArgs.add(value)
      } else if arg == "--triple" {
        triple = value
      } else if arg == "--cfg" {
        fileCfg = value
      } else {
        if value == "32" {
          longBits = 32
        } else if value == "64" {
          longBits = 64
        } else {
          printErr("bindgen: --long-bits must be 32 or 64")
          return 1
        }
      }
    } else if arg == "--check" {
      check = true
      i += 1
    } else if Str.startsWith(arg, "-") {
      printErr("bindgen: unknown option " + arg)
      printErr(bindgenUsage)
      return 1
    } else if header.length == 0 {
      header = arg
      i += 1
    } else {
      printErr("bindgen: one header expected, got a second: " + arg)
      return 1
    }
  }
  if header.length == 0 or packageName.length == 0 or allowFile.length == 0 {
    printErr(bindgenUsage)
    return 1
  }
  // `--triple` parses the header as that target sees it (its `_WIN32`
  // branches, its `<stdint.h>`) and sets the C data model: LLP64 on Windows
  // (32-bit `long`, 64-bit pointers), ILP32 on wasm32, LP64 elsewhere.  An
  // explicit `--long-bits` still overrides the `long` width.
  if triple.length > 0 {
    clangArgs.add("--target=" + triple)
    val explicitLong = argvHas(argv, "--long-bits")
    if Str.startsWith(triple, "wasm32") or Str.startsWith(triple, "i686") or Str.startsWith(triple, "i386") {
      pointerBits = 32
      if not explicitLong {
        longBits = 32
      }
    } else {
      pointerBits = 64
      if not explicitLong {
        longBits = if Str.contains(triple, "windows") { 32 } else { 64 }
      }
    }
  }
  if check and outPath.length == 0 {
    printErr("bindgen: --check needs -o <out.l> to compare against")
    return 1
  }
  val cfg = Bindgen.BindgenConfig(
    packageName = packageName,
    library = library,
    allow = newList(),
    userdata = newMap(),
    longBits = longBits,
    pointerBits = pointerBits,
    fileCfg = fileCfg
  )
  match File.readText(allowFile) {
    case Ok(text) -> {
      val problems = Bindgen.parseAllowList(text, cfg)
      if problems.count > 0 {
        for p in problems {
          printErr("bindgen: " + allowFile + ": " + p)
        }
        return 1
      }
    }
    case Err(_) -> {
      printErr("bindgen: cannot read " + allowFile)
      return 1
    }
  }
  if cfg.allow.count == 0 {
    printErr("bindgen: the allow-list selects nothing; name the functions, records and constants to bind")
    return 1
  }
  val args: List[String] = newList()
  args.add("-Xclang")
  args.add("-ast-dump=json")
  args.add("-fsyntax-only")
  for a in clangArgs {
    args.add(a)
  }
  args.add(header)
  var astText = ""
  match Process.runCapture("clang", args, 300000) {
    case Ok(res) -> {
      if res.exitCode != 0 {
        printErr("bindgen: clang failed on " + header + ":")
        printErr(res.stderr)
        return 1
      }
      astText = res.stdout
    }
    case Err(e) -> {
      printErr("bindgen: clang could not be started (" + e + "); bindgen needs clang on PATH")
      return 1
    }
  }
  val result = Bindgen.generateBindings(astText, cfg)
  for n in result.notes {
    printErr("bindgen: " + n)
  }
  if result.errors.count > 0 {
    for e in result.errors {
      printErr("bindgen: error: " + e)
    }
    return 1
  }
  // The file is committed and `lyric fmt --check` runs over it, so emit it formatted.
  val formatted = Fmt.formatSourceChecked(result.source)
  if not Fmt.fmtCheckIsOk(formatted) {
    printErr("bindgen: internal error: the generated source did not format: " + Fmt.fmtCheckMessage(formatted))
    return 1
  }
  val source = Fmt.fmtCheckText(formatted)
  if outPath.length == 0 {
    Console.print(source)
    return 0
  }
  if check {
    match File.readText(outPath) {
      case Ok(existing) -> {
        if existing == source {
          return 0
        }
        printErr("bindgen: " + outPath + " is out of date; regenerate it with `lyric bindgen`")
        return 1
      }
      case Err(_) -> {
        printErr("bindgen: " + outPath + " does not exist yet; generate it with `lyric bindgen` first")
        return 1
      }
    }
  }
  match File.writeText(outPath, source) {
    case Ok(_) -> {
      Console.println("bindgen: wrote " + outPath)
      0
    }
    case Err(_) -> {
      printErr("bindgen: cannot write " + outPath)
      1
    }
  }
}
