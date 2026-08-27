//! source_path_diagnostics_self_test.l — regression coverage for docs/63
//! §9.7 (issues #6282 / #6284): threading the real on-disk source path
//! through to diagnostics and the JVM `SourceFile` attribute.
//!
//! Before this fix, `Diagnostic`s printed via `Lyric.Pipeline.gate` carried
//! no file attribution at all for a single-file build — the finest
//! attribution available anywhere was the owning package name, and even
//! that was bypassed for parse-phase diagnostics (`pipeParseAndErase`
//! hardcoded `gate("", …)`). These tests spawn the real, just-built
//! `./bin/lyric` (this is the only way to observe the printed diagnostic
//! text; `Lyric.Pipeline.gate` writes straight to the process's own
//! stderr, which an in-process `Lyric.Emitter.emitProject` call cannot
//! intercept) and assert the real path appears.
//!
//! Assumes CWD is the repo root (`./bin/lyric` resolves relative to it) —
//! true for `make self-test`, `scripts/ci/self-test.sh`, and every CI job
//! that runs this file (`working-directory: ${{ github.workspace }}`).
//!
//! Run in CI via:
//!   lyric test lyric-compiler/lyric/source_path_diagnostics_self_test.l
@test_module
package Lyric.SourcePathDiagnosticsSelfTest

import Std.Core
import Std.Collections
import Std.Errors
import Std.File as File
import Std.String as Str
import Std.Path as Path
import Std.ProcessCapture as Capture
import Std.Testing
import Std.Uuid
import Std.Environment as Environment

func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", Environment.getVarOrDefault("TEMP", Environment.getVarOrDefault("TMP", "/tmp")))
}

func freshTempDir(label: in String): String {
  val root = Path.join(tempBase(), "lyric-srcpath-" + label + "-" + uuidToString(newUuid()))
  match File.createDir(root) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create temp dir " + root + ": " + IOError.message(e))
  }
  root
}

func cleanup(dir: in String): Unit {
  match File.deleteDirRecursive(dir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }
}

func lyricBinPath(): String {
  Path.join(Environment.currentDirectory(), "bin/lyric")
}

// A syntactically broken single-file program: a dangling `=` with no
// right-hand side, the same P0050/P0231 shape used across the parser
// self-tests.
func brokenSource(): String {
  "package Bad\n" + "import Std.Core\n" + "\n" + "func main(): Unit {\n" + "  val x =\n" + "}\n"
}

test "single-file dotnet build: a parse error names the real source path" {
  val dir = freshTempDir("dotnet")
  defer {
    cleanup(dir)
  }
  val srcPath = Path.join(dir, "bad.l")
  match File.writeText(srcPath, brokenSource()) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot write fixture: " + IOError.message(e))
  }
  val outPath = Path.join(dir, "bad.dll")
  val args: List[String] = newList()
  args.add("build")
  args.add(srcPath)
  args.add("--target")
  args.add("dotnet")
  args.add("-o")
  args.add(outPath)
  val result = Capture.runCaptureWithDiagnostics(lyricBinPath(), args, "")
  assertTrue(result.exitCode != 0, "a broken source file must fail the build")
  assertTrue(
    Str.contains(result.stderr, srcPath),
    "expected the real source path '" + srcPath + "' in stderr, got:\n" + result.stderr
  )
}

test "single-file jvm build: a parse error names the real source path" {
  val dir = freshTempDir("jvm")
  defer {
    cleanup(dir)
  }
  val srcPath = Path.join(dir, "bad.l")
  match File.writeText(srcPath, brokenSource()) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot write fixture: " + IOError.message(e))
  }
  val outPath = Path.join(dir, "bad.jar")
  val args: List[String] = newList()
  args.add("build")
  args.add(srcPath)
  args.add("--target")
  args.add("jvm")
  args.add("-o")
  args.add(outPath)
  val result = Capture.runCaptureWithDiagnostics(lyricBinPath(), args, "")
  assertTrue(result.exitCode != 0, "a broken source file must fail the build")
  assertTrue(
    Str.contains(result.stderr, srcPath),
    "expected the real source path '" + srcPath + "' in stderr, got:\n" + result.stderr
  )
}

// #6282 regression coverage: a multi-file [project.packages] entry whose
// SECOND file carries the error. This asserts the improvement this fix
// actually ships (parse-phase diagnostics for a project package are now
// labelled with the owning package name — `pipeParseAndErase` no longer
// hardcodes `gate("", …)`, closing that half of the docs/63 §9.7 gap) —
// it deliberately does NOT assert a correct file:line for the error,
// because that part of #6282 (per-file parse + merge, replacing the
// textual-concatenation `mergePackageSources`) is NOT fixed by this
// change: the merged compilation unit is still one blob, so the line
// number below is relative to that blob, not to `src/b.l`. See docs/63
// §9.7 and the #6282 issue for the remaining work.
test "multi-file project package: a parse error is labelled with the package name (line number still blob-relative, #6282 not fully closed)" {
  val dir = freshTempDir("mf")
  defer {
    cleanup(dir)
  }
  val srcDir = Path.join(dir, "src")
  match File.createDir(srcDir) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create src dir: " + IOError.message(e))
  }
  // 14 clean lines (matches the issue's own repro shape).
  val aSrc = "package Mf\n" + "import Std.Core\n" + "\n" + "func helperA(): Int {\n" + "  1\n" + "}\n" +
    "func helperB(): Int {\n" +
    "  2\n" +
    "}\n" +
    "func helperC(): Int {\n" +
    "  3\n" +
    "}\n" +
    "func helperD(): Int {\n" +
    "  4\n" +
    "}\n"
  // 6 lines, error on line 5 (a dangling `=`).
  val bSrc = "package Mf\n" + "import Std.Core\n" + "\n" + "func main(): Unit {\n" + "  val x =\n" + "}\n"
  match File.writeText(Path.join(srcDir, "a.l"), aSrc) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot write a.l: " + IOError.message(e))
  }
  match File.writeText(Path.join(srcDir, "b.l"), bSrc) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot write b.l: " + IOError.message(e))
  }
  val manifest = "[package]\n" + "name = \"Mf\"\n" + "version = \"0.0.1\"\n" + "\n" + "[project]\n" + "name = \"Mf\"\n" +
    "\n" +
    "[project.packages]\n" +
    "\"Mf\" = [\"src/a.l\", \"src/b.l\"]\n" +
    "\n" +
    "[dependencies]\n" +
    "Std = \"*\"\n"
  val mfPath = Path.join(dir, "lyric.toml")
  match File.writeText(mfPath, manifest) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot write lyric.toml: " + IOError.message(e))
  }
  val outPath = Path.join(dir, "out.dll")
  val args: List[String] = newList()
  args.add("build")
  args.add("--manifest")
  args.add(mfPath)
  args.add("--target")
  args.add("dotnet")
  args.add("-o")
  args.add(outPath)
  val result = Capture.runCaptureWithDiagnostics(lyricBinPath(), args, "")
  assertTrue(result.exitCode != 0, "a broken source file must fail the build")
  assertTrue(
    Str.contains(result.stderr, "Mf:"),
    "expected the package label 'Mf:' in stderr (parse-phase diagnostics must not bypass pkgLabel), got:\n" +
      result.stderr
  )
}
