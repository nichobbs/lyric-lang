// lyric/init.l — Lyric.Init: `lyric init` project scaffolder.
//
// Scaffolds a new application or library package: a `lyric.toml`, a
// `src/main.l` (or `src/lib.l` with `--lib`), and a `.gitignore`.  Derives the
// package name from the target directory's basename (UpperCamelCase-corrected)
// unless `--name` overrides it, and refuses to clobber an existing `lyric.toml`
// without `--force`.  See D084 / #1973's sibling #1972.

@runtime_checked
package Lyric.Init

import Std.Core
import Std.Errors
import Std.Console as Console
import Std.String as Str
import Std.Char as Char
import Std.File as File
import Std.Path as Path
import Std.Directory as Directory
import Std.Environment as Environment

pub record InitOptions {
  /// Target directory ("." for the current directory).
  dir:          String
  /// `--name` override; when None the name is derived from the directory.
  nameOverride: Option[String]
  /// `--lib` scaffolds a library (src/lib.l) instead of an app (src/main.l).
  isLib:        Bool
  /// `--force` overwrites an existing lyric.toml.
  force:        Bool
}

/// Derive a valid Lyric package name from a raw candidate (directory basename
/// or `--name`).  Capitalises a lowercase leading letter to honour the
/// UpperCamelCase convention, then validates that every character is a letter
/// or digit.  Returns `Err` with a user-facing message otherwise.
pub func derivePackageName(raw: in String): Result[String, String] {
  if Str.length(raw) == 0 {
    return Err(error = "empty package name; pass --name <Name>")
  }
  var name = raw
  val first = raw[0]
  if Char.isLetter(first) and not Char.isUpper(first) {
    name = ("" + Char.toUpper(first)) + Str.substring(raw, 1, Str.length(raw) - 1)
  }
  if not Char.isLetter(name[0]) {
    return Err(error = "package name must start with a letter (got '" + raw + "'); pass --name <Name>")
  }
  var i = 0
  while i < Str.length(name) {
    if not Char.isLetterOrDigit(name[i]) {
      return Err(error = "package name may contain only letters and digits (got '" + raw +
                         "'); pass --name <Name>")
    }
    i += 1
  }
  Ok(value = name)
}

func manifestContent(name: in String, isLib: in Bool): String {
  val srcEntry = if isLib { "src/lib.l" } else { "src/main.l" }
  "[package]\n" +
  "name = \"" + name + "\"\n" +
  "version = \"0.1.0\"\n" +
  "\n" +
  "[project]\n" +
  "name = \"" + name + "\"\n" +
  "output = \"single\"\n" +
  "output_assembly = \"" + name + ".dll\"\n" +
  "\n" +
  "[project.packages]\n" +
  "\"" + name + "\" = \"" + srcEntry + "\"\n" +
  "\n" +
  "[dependencies]\n"
}

func mainSource(name: in String): String {
  "package " + name + "\n" +
  "\n" +
  "import Std.Core\n" +
  "import Std.Console as Console\n" +
  "\n" +
  "pub func main(): Int {\n" +
  "  Console.println(\"Hello from " + name + "!\")\n" +
  "  0\n" +
  "}\n"
}

func libSource(name: in String): String {
  "package " + name + "\n" +
  "\n" +
  "import Std.Core\n" +
  "\n" +
  "/// Returns a friendly greeting.\n" +
  "pub func greet(who: in String): String {\n" +
  "  \"Hello, \" + who + \"!\"\n" +
  "}\n"
}

func gitignoreContent(): String {
  "# Lyric build / run / test output\n" +
  ".lyric-run/\n" +
  ".lyric-release/\n" +
  ".lyric-test/\n" +
  "bin/\n" +
  "target/\n" +
  "\n" +
  "# Dependency restore cache\n" +
  ".lyric/\n" +
  "\n" +
  "# Three-stage bootstrap workdir\n" +
  ".bootstrap/\n"
}

// Write `content` to `path`, reporting a clear `init:` error on failure.
func writeOrErr(path: in String, content: in String): Bool {
  match File.writeText(path, content) {
    case Ok(_)  -> true
    case Err(e) -> {
      Console.error("init: could not write " + path + ": " + IOError.message(e))
      false
    }
  }
}

func mkdirOrErr(path: in String): Bool {
  match Directory.createRecursive(path) {
    case Ok(_)  -> true
    case Err(e) -> {
      Console.error("init: could not create " + path + ": " + IOError.message(e))
      false
    }
  }
}

/// Scaffold a new package per `opts`.  Returns the process exit code.
pub func runInit(opts: in InitOptions): Int {
  val targetDir = opts.dir

  // Resolve the raw name source: --name, else the target directory basename
  // (falling back to the cwd basename when the target is ".").
  val rawName = match opts.nameOverride {
    case Some(n) -> n
    case None    -> {
      val base = Path.basename(targetDir)
      if base == "." or base == "" or Str.length(base) == 0 {
        Path.basename(Environment.currentDirectory())
      } else {
        base
      }
    }
  }
  val name = match derivePackageName(rawName) {
    case Ok(n)  -> n
    case Err(e) -> { Console.error("init: " + e); return 1 }
  }

  // Create the target directory (idempotent).
  if not Directory.exists(targetDir) {
    if not mkdirOrErr(targetDir) { return 1 }
  }

  // Refuse to clobber an existing manifest unless --force.
  val manifestPath = Path.join(targetDir, "lyric.toml")
  if File.fileExists(manifestPath) and not opts.force {
    Console.error("init: " + manifestPath + " already exists; pass --force to overwrite")
    return 1
  }

  val srcDir = Path.join(targetDir, "src")
  if not mkdirOrErr(srcDir) { return 1 }

  val srcName    = if opts.isLib { "lib.l" } else { "main.l" }
  val srcFile    = Path.join(srcDir, srcName)
  val srcContent = if opts.isLib { libSource(name) } else { mainSource(name) }

  if not writeOrErr(manifestPath, manifestContent(name, opts.isLib)) { return 1 }
  if not writeOrErr(srcFile, srcContent) { return 1 }

  // Only write .gitignore when absent — never clobber a user's existing one.
  val gitignorePath = Path.join(targetDir, ".gitignore")
  if not File.fileExists(gitignorePath) {
    if not writeOrErr(gitignorePath, gitignoreContent()) { return 1 }
  }

  val kind = if opts.isLib { "library" } else { "application" }
  Console.println("init: created " + kind + " package '" + name + "' in " + targetDir + "/")
  Console.println("  " + manifestPath)
  Console.println("  " + srcFile)
  Console.println("")
  Console.println("Next steps:")
  if targetDir != "." {
    Console.println("  cd " + targetDir)
  }
  if opts.isLib {
    Console.println("  lyric build          # compile the library")
  } else {
    Console.println("  lyric run src/main.l # build and run")
    Console.println("  lyric build          # build the project DLL")
  }
  0
}
