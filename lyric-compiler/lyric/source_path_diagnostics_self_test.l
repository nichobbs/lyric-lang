//! source_path_diagnostics_self_test.l — regression coverage for docs/63
//! §9.7 (issues #6282 / #6284): threading the real on-disk source path
//! through to diagnostics and the JVM `SourceFile` attribute. Also covers
//! two PR #6547 review follow-ups in the same "thread the path correctly"
//! family: #6610 (a single-file MSIL build routed through the project path
//! by a nearby `lyric.toml` must still label diagnostics with the real
//! path, not just the package name) and #6611 (the native bridge dropped
//! the threaded path on the floor entirely).
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

// #6611: `cli_build.l` threads `path = sourcePath` onto the native
// `EmitRequest`, but `Lyric.LlvmBridge.compileToNativeWithFlags` used to
// drop it on the floor — `pipeParseAndErase(..., "")` hardcoded an empty
// label unconditionally, so a native build's parse diagnostics regressed
// to the unlabelled `gate("", …)` form even though the real path was
// available one call up the stack. This never reaches the clang/link
// stage (the source is deliberately unparseable), so it needs no
// `LYRIC_RT_PATH` / `lyric-rt` build, unlike a native build that succeeds
// through codegen.
test "single-file native build: a parse error names the real source path" {
  val dir = freshTempDir("native")
  defer {
    cleanup(dir)
  }
  val srcPath = Path.join(dir, "bad.l")
  match File.writeText(srcPath, brokenSource()) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot write fixture: " + IOError.message(e))
  }
  val outPath = Path.join(dir, "bad")
  val args: List[String] = newList()
  args.add("build")
  args.add(srcPath)
  args.add("--target")
  args.add("native")
  args.add("-o")
  args.add(outPath)
  val result = Capture.runCaptureWithDiagnostics(lyricBinPath(), args, "")
  assertTrue(result.exitCode != 0, "a broken source file must fail the build")
  assertTrue(
    Str.contains(result.stderr, srcPath),
    "expected the real source path '" + srcPath + "' in stderr, got:\n" + result.stderr
  )
}

// #6610: `emitSingleFileOrProject` routes a single-file build through the
// project-shaped `emitProject` path whenever a nearby `lyric.toml`
// contributes anything (dependencies, features, or additional own
// packages) — a common real-world layout (an entry file next to a
// manifest). Before this fix, that path threaded only the package name
// (`pkg.name`) into `Msil.Bridge`'s diagnostics gate, never the real
// on-disk path `ProjectPackage.paths` already carries (the JVM bridge's
// equivalent path already did — `pkgPaths`), so a parse error here
// regressed to package-name-only attribution instead of naming the real
// file, unlike the plain single-file test above. A `[features]`-only
// manifest (no `[project.packages]`) is enough to trigger the routing
// without pulling in a second package, isolating the single-source-file
// shape this fix targets.
test "single-file dotnet build routed through the project path (nearby [features]-only manifest): a parse error still names the real source path" {
  val dir = freshTempDir("routed")
  defer {
    cleanup(dir)
  }
  val srcPath = Path.join(dir, "bad.l")
  match File.writeText(srcPath, brokenSource()) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot write fixture: " + IOError.message(e))
  }
  val manifest = "[package]\n" + "name = \"RoutedBad\"\n" + "version = \"0.0.1\"\n" + "\n" + "[features]\n" +
    "demo = []\n"
  val mfPath = Path.join(dir, "lyric.toml")
  match File.writeText(mfPath, manifest) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot write lyric.toml: " + IOError.message(e))
  }
  val outPath = Path.join(dir, "bad.dll")
  val args: List[String] = newList()
  args.add("build")
  args.add(srcPath)
  args.add("--target")
  args.add("dotnet")
  args.add("-o")
  args.add(outPath)
  // Deliberately no `--manifest` flag: the manifest must be auto-discovered
  // from `srcPath`'s own directory, matching the real-world "entry file
  // next to a lyric.toml" shape.
  val result = Capture.runCaptureWithDiagnostics(lyricBinPath(), args, "")
  assertTrue(result.exitCode != 0, "a broken source file must fail the build")
  assertTrue(
    Str.contains(result.stderr, srcPath),
    "expected the real source path '" + srcPath +
      "' in stderr (single-file build routed through the project path via a nearby lyric.toml, #6610), got:\n" +
      result.stderr
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
