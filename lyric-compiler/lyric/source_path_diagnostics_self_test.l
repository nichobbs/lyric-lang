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
  // A bare `Str.contains(result.stderr, srcPath)` is NOT discriminating here:
  // `cli_build.l` always appends a trailing "<srcPath>: build failed" summary
  // line whenever `hadError` is true, regardless of whether the underlying
  // per-diagnostic label threading actually worked, so that weaker assertion
  // would pass even against the pre-fix `gate("", …)` behaviour (#6654).
  // Anchor on the diagnostic's own label prefix (`<label>: error[P0050] …`,
  // `Lyric.DiagnosticUtil.diagReportAndAbortInPkg`'s format for the parser's
  // "expected an expression" diagnostic on the dangling `=`) so this only
  // passes when the diagnostic line ITSELF carries the real path.
  assertTrue(
    Str.contains(result.stderr, srcPath + ": error[P0050]"),
    "expected the P0050 diagnostic line itself to be labelled with the real source path '" + srcPath +
      "' (not just present somewhere in stderr via the catch-all 'build failed' line), got:\n" +
      result.stderr
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
  // See the dotnet test above (#6654): anchor on the diagnostic's own label
  // prefix, not the catch-all "build failed" summary line, which would pass
  // regardless of whether label threading actually worked.
  assertTrue(
    Str.contains(result.stderr, srcPath + ": error[P0050]"),
    "expected the P0050 diagnostic line itself to be labelled with the real source path '" + srcPath +
      "' (not just present somewhere in stderr via the catch-all 'build failed' line), got:\n" +
      result.stderr
  )
}

// #6678: `compileProjectToJarBundledWithFeatures`'s user-package
// `runMiddleEnd` call hardcoded an empty `pkgLabel` even though the real
// on-disk path was already resolved into `pkgPathByName` a few lines above
// (the same map `Jvm.Bridge` already consults for the `SourceFile`
// attribute). A file that PARSES cleanly but fails type-check (an
// unknown-name reference, so T0020 comes from `Lyric.TypeChecker.checkFile`
// via `pipeCheckAndMono`, not from `pipeParseAndErase`) therefore printed
// with no file attribution at all on `--target jvm`, even though
// `--target dotnet` on the identical file already names the real path
// (#6643). Unlike the dotnet #6643 regression below, no `lyric.toml`
// routing trick is needed: `emitJvmInProcess` already threads a plain
// single-file build straight into `compileProjectToJarBundledWithFeatures`
// (the same bundled multi-package-capable path a manifest build uses), and
// the JVM bridge's user-package type-check is unconditionally fatal
// (`tcFatalUserPkg = true`), unlike native's advisory type-check below.
test "single-file jvm build: a type error names the real source path" {
  val dir = freshTempDir("jvm-tc")
  defer {
    cleanup(dir)
  }
  val srcPath = Path.join(dir, "bad_tc.l")
  // Parses cleanly; `totallyUnknownFunctionName` triggers T0020 from the
  // type checker, not a parse-phase diagnostic.
  val src = "package JvmBadTc\n" + "import Std.Core\n" + "\n" + "func main(): Unit {\n" +
    "  val x = totallyUnknownFunctionName()\n" +
    "}\n"
  match File.writeText(srcPath, src) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot write fixture: " + IOError.message(e))
  }
  val outPath = Path.join(dir, "bad_tc.jar")
  val args: List[String] = newList()
  args.add("build")
  args.add(srcPath)
  args.add("--target")
  args.add("jvm")
  args.add("-o")
  args.add(outPath)
  val result = Capture.runCaptureWithDiagnostics(lyricBinPath(), args, "")
  assertTrue(result.exitCode != 0, "an unknown-name reference must fail the build")
  assertTrue(
    Str.contains(result.stderr, "T0020"),
    "expected a T0020 unknown-name diagnostic (type-check phase, not parse) in stderr, got:\n" + result.stderr
  )
  assertTrue(
    Str.contains(result.stderr, srcPath + ": error[T0020]"),
    "expected the T0020 diagnostic line itself to be labelled with the real source path '" + srcPath +
      "' (not an empty label) for a TYPE-CHECK-phase diagnostic on a single-file JVM build (#6678), got:\n" +
      result.stderr
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
  // See the dotnet test above (#6654): anchor on the diagnostic's own label
  // prefix, not the catch-all "build failed" summary line, which would pass
  // regardless of whether label threading actually worked.
  assertTrue(
    Str.contains(result.stderr, srcPath + ": error[P0050]"),
    "expected the P0050 diagnostic line itself to be labelled with the real source path '" + srcPath +
      "' (not just present somewhere in stderr via the catch-all 'build failed' line), got:\n" +
      result.stderr
  )
}

// #6677: `compileToNativeWithFlags` threads the real `path` parameter into
// the PARSE phase (`pipeParseAndErase`, see the native parse-error test
// above) but hardcoded an empty `pkgLabel` for the middle-end
// `MiddleEndOptions`, even though `path` was already a live parameter in
// scope a few lines up. Native's own TYPE CHECK is advisory
// (`Lyric.LlvmBridge.compileToNativeWithFlags` passes `tcFatal = false` —
// "the self-hosted checker lacks full builtin coverage"), so a bare T0020
// unknown-name reference alone does not GATE the native build the way it
// does on `--target dotnet`/`--target jvm` — it only gets echoed via the
// unlabelled `Lyric.DiagnosticUtil.diagReport` path. But the MODE CHECKER
// gate a few lines below the type check inside `Lyric.Pipeline.
// pipeCheckAndMono` IS unconditional (`gate(opts.pkgLabel, mcRes.
// diagnostics)`, not guarded by `tcFatal`) and consumes the exact same
// `pkgLabel` this fix repairs, so a genuine middle-end (non-parse)
// diagnostic that fails through THAT gate — V0010, a package declaring
// conflicting `@runtime_checked`/`@proof_required` verification-level
// annotations — is the fixture that actually exercises native's half of
// this bug.
test "single-file native build: a middle-end (mode-check) error names the real source path" {
  val dir = freshTempDir("native-tc")
  defer {
    cleanup(dir)
  }
  val srcPath = Path.join(dir, "bad_tc.l")
  // Parses cleanly; conflicting file-level verification-level annotations
  // trigger V0010 from the mode checker, not a parse-phase diagnostic.
  val src = "@runtime_checked\n" + "@proof_required\n" + "package NativeBadTc\n" + "import Std.Core\n" + "\n" +
    "func main(): Unit {\n" +
    "}\n"
  match File.writeText(srcPath, src) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot write fixture: " + IOError.message(e))
  }
  val outPath = Path.join(dir, "bad_tc")
  val args: List[String] = newList()
  args.add("build")
  args.add(srcPath)
  args.add("--target")
  args.add("native")
  args.add("-o")
  args.add(outPath)
  val result = Capture.runCaptureWithDiagnostics(lyricBinPath(), args, "")
  assertTrue(result.exitCode != 0, "conflicting verification-level annotations must fail the build")
  assertTrue(
    Str.contains(result.stderr, "V0010"),
    "expected a V0010 diagnostic (middle-end mode-check phase, not parse) in stderr, got:\n" + result.stderr
  )
  assertTrue(
    Str.contains(result.stderr, srcPath + ": error[V0010]"),
    "expected the V0010 diagnostic line itself to be labelled with the real source path '" + srcPath +
      "' (not an empty label) for a MIDDLE-END-phase diagnostic on a native build (#6677), got:\n" +
      result.stderr
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
  // See the plain single-file dotnet test above (#6654): a bare
  // `Str.contains(result.stderr, srcPath)` is NOT discriminating — the
  // catch-all "<srcPath>: build failed" summary line `cli_build.l` always
  // appends would satisfy it regardless of whether the routed-through-project
  // label threading (#6610) actually worked. Anchor on the diagnostic's own
  // label prefix instead.
  assertTrue(
    Str.contains(result.stderr, srcPath + ": error[P0050]"),
    "expected the P0050 diagnostic line itself to be labelled with the real source path '" + srcPath +
      "' (single-file build routed through the project path via a nearby lyric.toml, #6610), got:\n" +
      result.stderr
  )
}

// #6643: a project-build package that PARSES cleanly but fails type-check
// (an unknown-name reference, so the T0020 diagnostic comes from
// `Lyric.TypeChecker.checkFile` via `pipeCheckAndMono`, not from
// `pipeParseAndErase`) must still name the real on-disk source path when the
// package resolves to exactly one file — matching the #6610 parse-phase
// case above exactly. Before this fix, `ParsedUserPkg` carried the parsed
// `SourceFile` forward from Phase 1a but dropped the resolved `pkgLabel`
// (the real path or, for multi-file packages, the package name) on the
// floor, so the type-check phase's `MiddleEndOptions` fell back to the bare
// package name (`pp.name`) unconditionally — even when the real path WAS
// available and the parse phase, moments earlier, had already used it.
test "single-file dotnet build routed through the project path (nearby [features]-only manifest): a type error still names the real source path" {
  val dir = freshTempDir("routed-tc")
  defer {
    cleanup(dir)
  }
  val srcPath = Path.join(dir, "bad_tc.l")
  // Parses cleanly; `totallyUnknownFunctionName` triggers T0020 from the
  // type checker, not a parse-phase diagnostic.
  val src = "package RoutedBadTc\n" + "import Std.Core\n" + "\n" + "func main(): Unit {\n" +
    "  val x = totallyUnknownFunctionName()\n" +
    "}\n"
  match File.writeText(srcPath, src) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot write fixture: " + IOError.message(e))
  }
  val manifest = "[package]\n" + "name = \"RoutedBadTc\"\n" + "version = \"0.0.1\"\n" + "\n" + "[features]\n" +
    "demo = []\n"
  val mfPath = Path.join(dir, "lyric.toml")
  match File.writeText(mfPath, manifest) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot write lyric.toml: " + IOError.message(e))
  }
  val outPath = Path.join(dir, "bad_tc.dll")
  val args: List[String] = newList()
  args.add("build")
  args.add(srcPath)
  args.add("--target")
  args.add("dotnet")
  args.add("-o")
  args.add(outPath)
  // Deliberately no `--manifest` flag: the manifest must be auto-discovered
  // from `srcPath`'s own directory, matching #6610's routing shape.
  val result = Capture.runCaptureWithDiagnostics(lyricBinPath(), args, "")
  assertTrue(result.exitCode != 0, "an unknown-name reference must fail the build")
  assertTrue(
    Str.contains(result.stderr, "T0020"),
    "expected a T0020 unknown-name diagnostic (type-check phase, not parse) in stderr, got:\n" + result.stderr
  )
  // A bare `Str.contains(result.stderr, srcPath)` is NOT discriminating here:
  // `cli_build.l` always appends a trailing "<srcPath>: build failed" summary
  // line regardless of how the inner diagnostic itself was labelled, so that
  // weaker assertion would pass even against the pre-fix `pp.name` label.
  // Anchor on the diagnostic's own label prefix (`<label>: error[T0020] …`,
  // `Lyric.DiagnosticUtil.diagReportAndAbortInPkg`'s format) so this only
  // passes when the T0020 line ITSELF carries the real path, not just stderr
  // as a whole.
  assertTrue(
    Str.contains(result.stderr, srcPath + ": error[T0020]"),
    "expected the T0020 diagnostic line itself to be labelled with the real source path '" + srcPath +
      "' (not the bare package name) for a TYPE-CHECK-phase diagnostic on a project-routed single-file build (#6643), got:\n" +
      result.stderr
  )
}

// #6282 regression coverage: a multi-file [project.packages] entry whose
// SECOND file carries a parse error. Before this fix, `mergePackageSources`
// textually concatenated every file's body into one synthetic blob before
// parsing, so `Position.line` was relative to that blob, not to any file on
// disk — the diagnostic named a line number that did not exist in `b.l` at
// all (the issue's own repro: a 6-line file reported as "line 18") and
// never named a file, only the bare package name. `mergePackageSourcesWithOrigins`
// (`Lyric.Emitter`) now records, for every line of the merged blob, which
// on-disk file and original line it came from; `Lyric.DiagnosticUtil
// .diagFormatWithOrigin` consults that table when rendering a diagnostic
// instead of the merged blob's own numbering, so this asserts the actual
// file AND the actual line — not just the package label.
test "multi-file project package: a parse error in the second file names that file and its real line (#6282)" {
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
  // 6 lines: a dangling `=` on line 5; the parser only realizes an
  // expression is missing once it reaches the closing `}` on line 6 (the
  // same line a single-file build of this exact text reports — verified
  // directly against `brokenSource()`'s own single-file test above), so
  // the diagnostic itself lands on line 6, not line 5.
  val bSrc = "package Mf\n" + "import Std.Core\n" + "\n" + "func main(): Unit {\n" + "  val x =\n" + "}\n"
  val aPath = Path.join(srcDir, "a.l")
  val bPath = Path.join(srcDir, "b.l")
  match File.writeText(aPath, aSrc) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot write a.l: " + IOError.message(e))
  }
  match File.writeText(bPath, bSrc) {
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
    Str.contains(result.stderr, bPath + ": error[P0050]"),
    "expected the P0050 diagnostic to be labelled with b.l's own real path '" + bPath +
      "' (not the bare package name 'Mf'), got:\n" +
      result.stderr
  )
  assertTrue(
    Str.contains(result.stderr, "] 6:"),
    "expected the diagnostic to name b.l's own line 6 (the '}' where the parser realizes the '=' is dangling) — not a merged-blob-relative line number like 18, got:\n" +
      result.stderr
  )
}

// #6282's own literal repro: a type-check-phase (T0070) diagnostic on the
// second file of a multi-file package, exactly the shape the issue's
// "Observed" section reports as `Mf: error[T0070] 18:1: …` when the real
// error is on `src/b.l:5`. Unlike the parse-phase test above, this exercises
// `pipeCheckAndMono`'s `MiddleEndOptions.lineOrigins` path (via
// `ParsedUserPkg.origins`), not just `pipeParseAndErase`'s.
test "multi-file project package: a type error in the second file names that file and its real line (#6282 exact repro)" {
  val dir = freshTempDir("mf-tc")
  defer {
    cleanup(dir)
  }
  val srcDir = Path.join(dir, "src")
  match File.createDir(srcDir) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create src dir: " + IOError.message(e))
  }
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
  // 6 lines; line 5's trailing-expression type (String) mismatches the
  // declared return type (Int) — a T0070 from the type checker, not parse.
  // T0070 anchors on the enclosing function DECLARATION's own span (line
  // 4, `func gamma(): Int {`), not the offending expression's own line —
  // verified directly against an identical single-file build of this text.
  val bSrc = "package Mf\n" + "import Std.Core\n" + "\n" + "func gamma(): Int {\n" + "  \"not an Int\"\n" + "}\n"
  val aPath = Path.join(srcDir, "a.l")
  val bPath = Path.join(srcDir, "b.l")
  match File.writeText(aPath, aSrc) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot write a.l: " + IOError.message(e))
  }
  match File.writeText(bPath, bSrc) {
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
  assertTrue(result.exitCode != 0, "a trailing-expression type mismatch must fail the build")
  assertTrue(
    Str.contains(result.stderr, "T0070"),
    "expected a T0070 diagnostic (type-check phase, not parse) in stderr, got:\n" + result.stderr
  )
  assertTrue(
    Str.contains(result.stderr, bPath + ": error[T0070]"),
    "expected the T0070 diagnostic to be labelled with b.l's own real path '" + bPath +
      "' (not the bare package name 'Mf'), got:\n" +
      result.stderr
  )
  assertTrue(
    Str.contains(result.stderr, "] 4:"),
    "expected the diagnostic to name b.l's own line 4 (the enclosing 'func gamma(): Int {' declaration T0070 anchors on), got:\n" +
      result.stderr
  )
}

// #6282's "Acceptance" bullet: single-file packages must be entirely
// unaffected by the multi-file origin machinery — `mergePackageSourcesWithOrigins`
// returns early with an empty origins list at `sources.count == 1`, so this
// asserts the plain single-file project-routed case still reports the real
// path with no behaviour change (mirrors the #6610 test above, but through
// a genuine `[project.packages]` single-file entry rather than the
// nearby-manifest auto-routing shape).
test "single-file project package (one entry in [project.packages]): a parse error still names the real source path (#6282 unaffected-by-fix guard)" {
  val dir = freshTempDir("mf-single")
  defer {
    cleanup(dir)
  }
  val srcDir = Path.join(dir, "src")
  match File.createDir(srcDir) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create src dir: " + IOError.message(e))
  }
  val aPath = Path.join(srcDir, "a.l")
  match File.writeText(aPath, brokenSource()) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot write a.l: " + IOError.message(e))
  }
  val manifest = "[package]\n" + "name = \"MfSingle\"\n" + "version = \"0.0.1\"\n" + "\n" + "[project]\n" +
    "name = \"MfSingle\"\n" +
    "\n" +
    "[project.packages]\n" +
    "\"MfSingle\" = [\"src/a.l\"]\n" +
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
    Str.contains(result.stderr, aPath + ": error[P0050]"),
    "expected the P0050 diagnostic to be labelled with a.l's real path '" + aPath +
      "' for a single-entry [project.packages] package, got:\n" +
      result.stderr
  )
}

// #6642: `Lyric.TestSynth`'s rewrite for `@test_module` files (which backs
// `lyric test`) sliced only `packageDecl.span` when building the rewritten
// source, dropping the module-level `//!` doc-comment header and the
// `@test_module` annotation line — both live in separate `SourceFile`
// fields ahead of `packageDecl` — entirely. That shifted every subsequent
// line number in the rewritten (and then re-parsed) source by however many
// lines the header occupied: `lyric test` named the right file (the
// #6282/#6284 fix above) but the WRONG line. `helper()` is a plain
// (non-`test`, non-`fixture`) item the rewrite always copies byte-for-byte,
// isolating the header-drop bug from the `test { }` block's own rewrite.
func headerLineShiftTestModuleSource(): String {
  "//! Header line 1.\n" + "//! Header line 2.\n" + "//! Header line 3.\n" + "@test_module\n" +
    "package HeaderLineRepro\n" +
    "\n" +
    "import Std.Testing\n" +
    "\n" +
    "func helper(): Int {\n" +
    "  totallyUnknownIdentifierXYZ\n" +
    "}\n" +
    "\n" +
    "test \"trivial\" {\n" +
    "  assertTrue(true, \"x\")\n" +
    "}\n"
}

test "lyric test: a compile error names the real line despite a multi-line module //! header (#6642)" {
  val dir = freshTempDir("testsynth-header")
  defer {
    cleanup(dir)
  }
  val srcPath = Path.join(dir, "header_line_repro.l")
  match File.writeText(srcPath, headerLineShiftTestModuleSource()) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot write fixture: " + IOError.message(e))
  }
  val args: List[String] = newList()
  args.add("test")
  args.add(srcPath)
  // `runCaptureWithDiagnostics`'s default 10s cap is tuned for the other
  // tests in this file, which fail during PARSE (before ever touching the
  // stdlib import graph) and so return almost immediately. This fixture
  // synthesises a full `@test_module` unit that imports `Std.Testing` and
  // runs a real type-check over the whole stdlib closure — routinely well
  // past 10s under CI/sandbox CPU contention — so it needs the same
  // generous explicit timeout `cmdTest` itself uses for its own subprocess
  // calls.
  val result = Capture.runCaptureWithDiagnosticsTimeout(lyricBinPath(), args, "", 300000)
  assertTrue(not result.timedOut, "lyric test timed out before producing a diagnostic")
  assertTrue(result.exitCode != 0, "an unresolved identifier inside helper() must fail the build")
  assertTrue(
    Str.contains(result.stderr, srcPath),
    "expected the real source path '" + srcPath + "' in stderr, got:\n" + result.stderr
  )
  // The error is `totallyUnknownIdentifierXYZ` on line 10 of the ORIGINAL
  // file. Before the fix, dropping the 3-line header + the `@test_module`
  // line (4 lines total) shifted the reported line to 6, not 10.
  assertTrue(
    Str.contains(result.stderr, "] 10:"),
    "expected the diagnostic to name line 10 (the 'totallyUnknownIdentifierXYZ' reference in helper()), " +
      "not a header-shifted line, got:\n" +
      result.stderr
  )
}

// #6826 (claude-review finding on #6825): the MSIL project bundle's weave
// loop (`Msil.Bridge`'s Phase 3, split from `pipeCheckAndMono` so aspect
// templates from every package's post-mono file are collected before any
// package weaves) hardcoded `pipeWeave(perPkgFiles[li], allTemplates, "",
// noBundleWeaveOrigins)` — an empty label AND an empty origins table —
// even though `parsedPkgs[li].label` / `.origins` (the SAME pair the
// typecheck phase a few lines earlier already resolved and used) were in
// scope. A weave-time diagnostic (A0042/A0043/A0044) on a multi-file MSIL
// project package therefore printed with NO file attribution at all,
// unlike every other phase (#6282's own fix) and unlike the identical JVM
// build (which routes weave through `Lyric.Pipeline.pipeMiddleEnd`,
// threading `opts.pkgLabel`/`opts.lineOrigins` unconditionally). This
// fixture's aspect config field has no default, mirroring
// `weaver_ci_test.l`'s `testConfigNoDefaultEmitsA0044` fixture exactly
// (A0044 is a WEAVE-phase diagnostic, not parse/typecheck/modecheck, so it
// specifically exercises the loop this fix touches).
test "multi-file project package (dotnet): a weave-time error (A0044) in the second file names that file and its real line (#6826)" {
  val dir = freshTempDir("mf-weave")
  defer {
    cleanup(dir)
  }
  val srcDir = Path.join(dir, "src")
  match File.createDir(srcDir) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create src dir: " + IOError.message(e))
  }
  val aSrc = "package WeaveMf\n" + "import Std.Core\n" + "func helperA(): Int {\n" + "  1\n" + "}\n" +
    "func helperB(): Int {\n" +
    "  2\n" +
    "}\n"
  // 11 lines; `config.undefaulted` (line 7) has no literal default, so
  // A0044 fires at weave time when `d` (matched by `name like "d"`) is
  // woven.
  val bSrc = "package WeaveMf\n" + "import Std.Core\n" + "aspect Limit {\n" + "  config { undefaulted: Int }\n" +
    "  matches: name like \"d\"\n" +
    "  around(args) -> ret {\n" +
    "    val v = config.undefaulted\n" +
    "    proceed(args)\n" +
    "  }\n" +
    "}\n" +
    "func d(): Int { 0 }\n" +
    "func main(): Unit {}\n"
  val aPath = Path.join(srcDir, "a.l")
  val bPath = Path.join(srcDir, "b.l")
  match File.writeText(aPath, aSrc) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot write a.l: " + IOError.message(e))
  }
  match File.writeText(bPath, bSrc) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot write b.l: " + IOError.message(e))
  }
  val manifest = "[package]\n" + "name = \"WeaveMf\"\n" + "version = \"0.0.1\"\n" + "\n" + "[project]\n" +
    "name = \"WeaveMf\"\n" +
    "\n" +
    "[project.packages]\n" +
    "\"WeaveMf\" = [\"src/a.l\", \"src/b.l\"]\n" +
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
  assertTrue(result.exitCode != 0, "a config field with no default referenced by a matched aspect must fail the build")
  assertTrue(
    Str.contains(result.stderr, "A0044"),
    "expected an A0044 diagnostic (weave phase, not parse/typecheck/modecheck) in stderr, got:\n" + result.stderr
  )
  assertTrue(
    Str.contains(result.stderr, bPath + ": error[A0044]"),
    "expected the A0044 diagnostic to be labelled with b.l's own real path '" + bPath +
      "' (not an empty label) for a WEAVE-phase diagnostic on a multi-file MSIL project package (#6826), got:\n" +
      result.stderr
  )
  assertTrue(
    Str.contains(result.stderr, "] 7:"),
    "expected the diagnostic to name b.l's own line 7 ('val v = config.undefaulted'), got:\n" + result.stderr
  )
}

// #6824 item 1: native project-package diagnostics get the SAME real-path
// attribution the MSIL/JVM project bridges already had — before this fix,
// `Lyric.LlvmBridge.NativeSourcePackage` had no `path` field at all and
// `compileProjectToNativeWithFlags` had no `origins` parameter, so a
// multi-file `[project.packages]` entry (routed through `--target native`)
// reported diagnostics under the bare package name only, with a merged-blob-
// relative line number — the exact #6282 symptom, but never fixed for native
// because native's own `NativeSourcePackage` predates #6282 with no path
// field to build on. Mirrors the dotnet/jvm `#6282` parse-error test above
// exactly, just routed through `--target native`.
test "multi-file project package (native): a parse error in the second file names that file and its real line (#6824)" {
  val dir = freshTempDir("mf-native")
  defer {
    cleanup(dir)
  }
  val srcDir = Path.join(dir, "src")
  match File.createDir(srcDir) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create src dir: " + IOError.message(e))
  }
  val aSrc = "package MfNative\n" + "import Std.Core\n" + "\n" + "func helperA(): Int {\n" + "  1\n" + "}\n" +
    "func helperB(): Int {\n" +
    "  2\n" +
    "}\n"
  // Same dangling-`=` shape as the dotnet/jvm #6282 fixtures: the parser
  // only realizes the expression is missing once it reaches the closing `}`
  // on line 6.
  val bSrc = "package MfNative\n" + "import Std.Core\n" + "\n" + "func main(): Unit {\n" + "  val x =\n" + "}\n"
  val aPath = Path.join(srcDir, "a.l")
  val bPath = Path.join(srcDir, "b.l")
  match File.writeText(aPath, aSrc) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot write a.l: " + IOError.message(e))
  }
  match File.writeText(bPath, bSrc) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot write b.l: " + IOError.message(e))
  }
  val manifest = "[package]\n" + "name = \"MfNative\"\n" + "version = \"0.0.1\"\n" + "\n" + "[project]\n" +
    "name = \"MfNative\"\n" +
    "\n" +
    "[project.packages]\n" +
    "\"MfNative\" = [\"src/a.l\", \"src/b.l\"]\n" +
    "\n" +
    "[dependencies]\n" +
    "Std = \"*\"\n"
  val mfPath = Path.join(dir, "lyric.toml")
  match File.writeText(mfPath, manifest) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot write lyric.toml: " + IOError.message(e))
  }
  val outPath = Path.join(dir, "out")
  val args: List[String] = newList()
  args.add("build")
  args.add("--manifest")
  args.add(mfPath)
  args.add("--target")
  args.add("native")
  args.add("-o")
  args.add(outPath)
  val result = Capture.runCaptureWithDiagnostics(lyricBinPath(), args, "")
  assertTrue(result.exitCode != 0, "a broken source file must fail the build")
  assertTrue(
    Str.contains(result.stderr, bPath + ": error[P0050]"),
    "expected the P0050 diagnostic to be labelled with b.l's own real path '" + bPath +
      "' (not the bare package name 'MfNative') on a multi-file NATIVE project package (#6824), got:\n" +
      result.stderr
  )
  assertTrue(
    Str.contains(result.stderr, "] 6:"),
    "expected the diagnostic to name b.l's own line 6 — not a merged-blob-relative line number, got:\n" + result.stderr
  )
}

// #6824 item 2: codegen-phase (F0xxx) diagnostics on a multi-file MSIL
// project package resolve through the SAME `PackageLineOrigins` table the
// parse/typecheck/modecheck/elaborate/weave gates already use, instead of
// falling back to the bare package name. `Msil.Bridge`'s F0025 (try-catch
// expression with a Unit-yielding, non-diverging catch arm beside a
// value-yielding try body — `msil_codegen_diag_self_test.l`'s own single-file
// repro) never routes through `Lyric.Pipeline.gate` (codegen diagnostics
// accumulate on `CodegenCtx.diagnostics` directly), so #6282/#6824's earlier
// items never touched it. `wrap[T]`'s bad try/catch and its `main()` caller
// both live in the SECOND file so the origin table (not just the label) is
// exercised.
test "multi-file project package (dotnet): a codegen-phase error (F0025) in the second file names that file and its real line (#6824)" {
  val dir = freshTempDir("mf-codegen")
  defer {
    cleanup(dir)
  }
  val srcDir = Path.join(dir, "src")
  match File.createDir(srcDir) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create src dir: " + IOError.message(e))
  }
  val aSrc = "package CodegenMf\n" + "import Std.Core\n" + "func helperA(): Int {\n" + "  1\n" + "}\n" +
    "func helperB(): Int {\n" +
    "  2\n" +
    "}\n"
  // `wrap[T]`'s try body yields `T` (bound to `Int` at the `wrap(1)` call
  // site below via `Lyric.Mono`) while its catch arm yields `Unit` — the
  // F0025 shape from `msil_codegen_diag_self_test.l`. No blank line before
  // `func wrap`, so the `catch` keyword lands on line 6, column 5, matching
  // that file's own single-file fixture exactly.
  val bSrc = "package CodegenMf\n" + "import Std.Core\n" + "func wrap[T](v: in T): T {\n" + "  val r = try {\n" +
    "    v\n" +
    "  } catch Bug as _ {\n" +
    "    println(0)\n" +
    "  }\n" +
    "  r\n" +
    "}\n" +
    "func main(): Unit {\n" +
    "  println(toString(wrap(1)))\n" +
    "}\n"
  val aPath = Path.join(srcDir, "a.l")
  val bPath = Path.join(srcDir, "b.l")
  match File.writeText(aPath, aSrc) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot write a.l: " + IOError.message(e))
  }
  match File.writeText(bPath, bSrc) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot write b.l: " + IOError.message(e))
  }
  val manifest = "[package]\n" + "name = \"CodegenMf\"\n" + "version = \"0.0.1\"\n" + "\n" + "[project]\n" +
    "name = \"CodegenMf\"\n" +
    "\n" +
    "[project.packages]\n" +
    "\"CodegenMf\" = [\"src/a.l\", \"src/b.l\"]\n" +
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
  assertTrue(result.exitCode != 0, "a try-catch expression with mismatched branch types must fail the build")
  assertTrue(
    Str.contains(result.stderr, "F0025"),
    "expected an F0025 diagnostic (codegen phase, not parse/typecheck/modecheck/weave) in stderr, got:\n" +
      result.stderr
  )
  assertTrue(
    Str.contains(result.stderr, bPath + ": error[F0025]"),
    "expected the F0025 diagnostic to be labelled with b.l's own real path '" + bPath +
      "' (not the bare package name 'CodegenMf') for a CODEGEN-phase diagnostic on a multi-file MSIL project package (#6824), got:\n" +
      result.stderr
  )
  assertTrue(
    Str.contains(result.stderr, "] 6:"),
    "expected the diagnostic to name b.l's own line 6 (the 'catch' keyword) — not a merged-blob-relative line number, got:\n" +
      result.stderr
  )
}

// #7034: the multi-file F0025 case above only exercises a package whose
// `origins` table is populated (`origins.count > 0`), which never hits
// `DiagUtil.resolveLineOrigin`'s empty-`origins` fallback branch — the one
// that uses whatever label string was passed in verbatim. A single-file
// entry in `[project.packages]` (the #6282-unaffected-by-fix-guard shape
// from the parse-phase test above) has an empty `origins` table, so it's
// the one case that actually exercises the fallback label
// `abortOnCodegenDiagnosticsMsilInPkgWithOrigins` is given — and the
// codegen-phase call site was passing the bare `perPkgNames[ci]` package
// name there instead of `parsedPkgs[ci].label` (the real-path-or-name field
// the middle-end gate a few lines above already uses for the same index),
// so a single-file package's F0021–F0025/F0034 diagnostics fell back to the
// bare package name even though the real path was already known.
test "single-file project package (one entry in [project.packages]): a codegen-phase error (F0025) still names the real source path (#7034)" {
  val dir = freshTempDir("mf-codegen-single")
  defer {
    cleanup(dir)
  }
  val srcDir = Path.join(dir, "src")
  match File.createDir(srcDir) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create src dir: " + IOError.message(e))
  }
  // Same F0025 shape as the multi-file case above (`wrap[T]`'s try body
  // yields `T` while its catch arm yields `Unit`), but as a single file so
  // this package's `origins` table is empty and the fallback label path is
  // actually exercised. No blank line before `func wrap`, so `catch` lands
  // on line 6, column 5, matching `msil_codegen_diag_self_test.l`'s own
  // single-file fixture.
  val aSrc = "package CodegenSingle\n" + "import Std.Core\n" + "func wrap[T](v: in T): T {\n" + "  val r = try {\n" +
    "    v\n" +
    "  } catch Bug as _ {\n" +
    "    println(0)\n" +
    "  }\n" +
    "  r\n" +
    "}\n" +
    "func main(): Unit {\n" +
    "  println(toString(wrap(1)))\n" +
    "}\n"
  val aPath = Path.join(srcDir, "a.l")
  match File.writeText(aPath, aSrc) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot write a.l: " + IOError.message(e))
  }
  val manifest = "[package]\n" + "name = \"CodegenSingle\"\n" + "version = \"0.0.1\"\n" + "\n" + "[project]\n" +
    "name = \"CodegenSingle\"\n" +
    "\n" +
    "[project.packages]\n" +
    "\"CodegenSingle\" = [\"src/a.l\"]\n" +
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
  assertTrue(result.exitCode != 0, "a try-catch expression with mismatched branch types must fail the build")
  assertTrue(
    Str.contains(result.stderr, aPath + ": error[F0025]"),
    "expected the F0025 diagnostic to be labelled with a.l's own real path '" + aPath +
      "' (not the bare package name 'CodegenSingle') for a CODEGEN-phase diagnostic on a single-file [project.packages] entry (#7034), got:\n" +
      result.stderr
  )
}

// #6824 item 3: `pipeExpandAndRewrite`'s two gates (docs/58 wire/config-
// template expansion, and same-file interface-default-method inheritance)
// previously hardcoded `gate("", noOrigins, …)` unconditionally, even though
// every bridge call site reaches this function AFTER already resolving a
// real label/origins pair for the exact same package (`ParsedUserPkg.label`/
// `.origins` on the MSIL side). `Lyric.ImplDefaults.inheritDefaultsFile`'s
// T0117 (an unresolved diamond default-method conflict — two interfaces
// defaulting the same method name onto one target, no override) is the
// smallest available trigger for this specific gate: unlike A0044 above
// (the WEAVE phase, a separate call further down the pipeline), T0117 fires
// inside `pipeExpandAndRewrite` itself, before typecheck ever runs.
test "multi-file project package (dotnet): an impl-default diamond conflict (T0117) in the second file names that file (#6824)" {
  val dir = freshTempDir("mf-impldefault")
  defer {
    cleanup(dir)
  }
  val srcDir = Path.join(dir, "src")
  match File.createDir(srcDir) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create src dir: " + IOError.message(e))
  }
  val aSrc = "package ImplDiamondMf\n" + "import Std.Core\n" + "interface Alpha {\n" +
    "  func label(self: in Self): Int {\n" +
    "    1\n" +
    "  }\n" +
    "}\n" +
    "interface Beta {\n" +
    "  func label(self: in Self): Int {\n" +
    "    2\n" +
    "  }\n" +
    "}\n"
  val bSrc = "package ImplDiamondMf\n" + "import Std.Core\n" + "record Thing {\n" + "  base: Int\n" + "}\n" +
    "impl Alpha for Thing {\n" +
    "}\n" +
    "impl Beta for Thing {\n" +
    "}\n" +
    "func main(): Unit {\n" +
    "  println(toString(Thing(base = 0).label()))\n" +
    "}\n"
  val aPath = Path.join(srcDir, "a.l")
  val bPath = Path.join(srcDir, "b.l")
  match File.writeText(aPath, aSrc) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot write a.l: " + IOError.message(e))
  }
  match File.writeText(bPath, bSrc) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot write b.l: " + IOError.message(e))
  }
  val manifest = "[package]\n" + "name = \"ImplDiamondMf\"\n" + "version = \"0.0.1\"\n" + "\n" + "[project]\n" +
    "name = \"ImplDiamondMf\"\n" +
    "\n" +
    "[project.packages]\n" +
    "\"ImplDiamondMf\" = [\"src/a.l\", \"src/b.l\"]\n" +
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
  assertTrue(result.exitCode != 0, "an unresolved diamond default-method conflict must fail the build")
  assertTrue(
    Str.contains(result.stderr, "T0117"),
    "expected a T0117 diagnostic (pipeExpandAndRewrite's impl-default-inheritance gate) in stderr, got:\n" +
      result.stderr
  )
  assertTrue(
    Str.contains(result.stderr, bPath + ": error[T0117]"),
    "expected the T0117 diagnostic to be labelled with b.l's own real path '" + bPath +
      "' (not the bare package name 'ImplDiamondMf' or an empty label) on a multi-file MSIL project package (#6824), got:\n" +
      result.stderr
  )
}

// #6824 item 3, native sibling: the dotnet T0117 test above only exercises
// `Msil.Bridge`'s call sites into `pipeExpandAndRewrite`. The native path
// (`Lyric.LlvmBridge.compileProjectToNativeWithFlags`) reaches the exact same
// unconditional `ImplDefaults.inheritDefaultsFile` gate via its own
// `nativePkgLabelAt`/`nativePkgOriginsAt`-resolved call — `pipeExpandAndRewrite`
// itself has no per-target branch — but that plumbing had no test of its own,
// only the parse-phase P0050 case above (#6824 item 1) and manual code
// inspection. Identical `ImplDiamondMf`-shaped fixture, routed through
// `--target native`.
test "multi-file project package (native): an impl-default diamond conflict (T0117) in the second file names that file (#6824)" {
  val dir = freshTempDir("mf-impldefault-native")
  defer {
    cleanup(dir)
  }
  val srcDir = Path.join(dir, "src")
  match File.createDir(srcDir) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create src dir: " + IOError.message(e))
  }
  val aSrc = "package ImplDiamondMfNative\n" + "import Std.Core\n" + "interface Alpha {\n" +
    "  func label(self: in Self): Int {\n" +
    "    1\n" +
    "  }\n" +
    "}\n" +
    "interface Beta {\n" +
    "  func label(self: in Self): Int {\n" +
    "    2\n" +
    "  }\n" +
    "}\n"
  val bSrc = "package ImplDiamondMfNative\n" + "import Std.Core\n" + "record Thing {\n" + "  base: Int\n" + "}\n" +
    "impl Alpha for Thing {\n" +
    "}\n" +
    "impl Beta for Thing {\n" +
    "}\n" +
    "func main(): Unit {\n" +
    "  println(toString(Thing(base = 0).label()))\n" +
    "}\n"
  val aPath = Path.join(srcDir, "a.l")
  val bPath = Path.join(srcDir, "b.l")
  match File.writeText(aPath, aSrc) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot write a.l: " + IOError.message(e))
  }
  match File.writeText(bPath, bSrc) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot write b.l: " + IOError.message(e))
  }
  val manifest = "[package]\n" + "name = \"ImplDiamondMfNative\"\n" + "version = \"0.0.1\"\n" + "\n" + "[project]\n" +
    "name = \"ImplDiamondMfNative\"\n" +
    "\n" +
    "[project.packages]\n" +
    "\"ImplDiamondMfNative\" = [\"src/a.l\", \"src/b.l\"]\n" +
    "\n" +
    "[dependencies]\n" +
    "Std = \"*\"\n"
  val mfPath = Path.join(dir, "lyric.toml")
  match File.writeText(mfPath, manifest) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot write lyric.toml: " + IOError.message(e))
  }
  val outPath = Path.join(dir, "out")
  val args: List[String] = newList()
  args.add("build")
  args.add("--manifest")
  args.add(mfPath)
  args.add("--target")
  args.add("native")
  args.add("-o")
  args.add(outPath)
  val result = Capture.runCaptureWithDiagnostics(lyricBinPath(), args, "")
  assertTrue(result.exitCode != 0, "an unresolved diamond default-method conflict must fail the build")
  assertTrue(
    Str.contains(result.stderr, "T0117"),
    "expected a T0117 diagnostic (pipeExpandAndRewrite's impl-default-inheritance gate) in stderr, got:\n" +
      result.stderr
  )
  assertTrue(
    Str.contains(result.stderr, bPath + ": error[T0117]"),
    "expected the T0117 diagnostic to be labelled with b.l's own real path '" + bPath +
      "' (not the bare package name 'ImplDiamondMfNative' or an empty label) on a multi-file NATIVE project package (#6824), got:\n" +
      result.stderr
  )
}

// #6824 item 4: the `--target jvm` sibling of the dotnet test above.
// `Jvm.Bridge.compileProjectToJarBundledWithRestored`'s `pkgOriginsByName`
// plumbing was manually verified working during #6825's own review response,
// but had no automated regression coverage — unlike this repo's usual
// convention of dual-target self-tests for cross-target changes (e.g.
// `bitwise_self_test.l --target jvm`). Identical fixture to the dotnet case
// above (a weave-time A0044 on the second file of a two-file project
// package), just routed through `--target jvm`, so a real JVM regression in
// `pkgOriginsByName`'s per-package lookup (keyed by package name, resolved
// during the JVM bridge's own parse loop) fails CI instead of relying on a
// one-off manual check.
test "multi-file project package (jvm): a weave-time error (A0044) in the second file names that file and its real line (#6824)" {
  val dir = freshTempDir("mf-weave-jvm")
  defer {
    cleanup(dir)
  }
  val srcDir = Path.join(dir, "src")
  match File.createDir(srcDir) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create src dir: " + IOError.message(e))
  }
  val aSrc = "package WeaveMfJvm\n" + "import Std.Core\n" + "func helperA(): Int {\n" + "  1\n" + "}\n" +
    "func helperB(): Int {\n" +
    "  2\n" +
    "}\n"
  // Same shape as the dotnet fixture: `config.undefaulted` (line 7) has no
  // literal default, so A0044 fires at weave time when `d` (matched by
  // `name like "d"`) is woven.
  val bSrc = "package WeaveMfJvm\n" + "import Std.Core\n" + "aspect Limit {\n" + "  config { undefaulted: Int }\n" +
    "  matches: name like \"d\"\n" +
    "  around(args) -> ret {\n" +
    "    val v = config.undefaulted\n" +
    "    proceed(args)\n" +
    "  }\n" +
    "}\n" +
    "func d(): Int { 0 }\n" +
    "func main(): Unit {}\n"
  val aPath = Path.join(srcDir, "a.l")
  val bPath = Path.join(srcDir, "b.l")
  match File.writeText(aPath, aSrc) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot write a.l: " + IOError.message(e))
  }
  match File.writeText(bPath, bSrc) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot write b.l: " + IOError.message(e))
  }
  val manifest = "[package]\n" + "name = \"WeaveMfJvm\"\n" + "version = \"0.0.1\"\n" + "\n" + "[project]\n" +
    "name = \"WeaveMfJvm\"\n" +
    "\n" +
    "[project.packages]\n" +
    "\"WeaveMfJvm\" = [\"src/a.l\", \"src/b.l\"]\n" +
    "\n" +
    "[dependencies]\n" +
    "Std = \"*\"\n"
  val mfPath = Path.join(dir, "lyric.toml")
  match File.writeText(mfPath, manifest) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot write lyric.toml: " + IOError.message(e))
  }
  val outPath = Path.join(dir, "out.jar")
  val args: List[String] = newList()
  args.add("build")
  args.add("--manifest")
  args.add(mfPath)
  args.add("--target")
  args.add("jvm")
  args.add("-o")
  args.add(outPath)
  val result = Capture.runCaptureWithDiagnostics(lyricBinPath(), args, "")
  assertTrue(result.exitCode != 0, "a config field with no default referenced by a matched aspect must fail the build")
  assertTrue(
    Str.contains(result.stderr, "A0044"),
    "expected an A0044 diagnostic (weave phase, not parse/typecheck/modecheck) in stderr, got:\n" + result.stderr
  )
  assertTrue(
    Str.contains(result.stderr, bPath + ": error[A0044]"),
    "expected the A0044 diagnostic to be labelled with b.l's own real path '" + bPath +
      "' (not an empty label) for a WEAVE-phase diagnostic on a multi-file JVM project package (#6824), got:\n" +
      result.stderr
  )
  assertTrue(
    Str.contains(result.stderr, "] 7:"),
    "expected the diagnostic to name b.l's own line 7 ('val v = config.undefaulted'), got:\n" + result.stderr
  )
}
