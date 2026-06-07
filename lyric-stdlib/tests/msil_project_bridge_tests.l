//! lyric-compiler/tests/msil_project_bridge_tests.l — end-to-end tests for
//! the self-hosted multi-package MSIL bridge (`Msil.Bridge.compileProjectToMsil`).
//!
//! Each test bundles multiple Lyric packages into one PE via the in-process
//! self-hosted pipeline, runs the produced DLL via `dotnet exec`, and
//! asserts on stdout.  Mirrors the F# `SelfHostedMsilProjectBridgeTests.fs`
//! that this file replaces (#1183: tests live in Lyric, not F#, per
//! CLAUDE.md's "F# surface is frozen" policy).
//!
//! Discovery: `bootstrap/tests/Lyric.Emitter.Tests/StdlibLyricTests.fs`
//! walks `lyric-stdlib/tests/*.l` automatically; this file is picked up
//! without a dedicated runner shim (#1200).
package Lyric.Tests.MsilProjectBridge

import Std.Core
import Std.Collections
import Std.Errors
import Std.File as File
import Std.String as Str
// before Path so Path.join/2 wins over Str.join/2
import Std.Path as Path
import Std.ProcessCapture as Capture
import Std.Testing
import Std.Uuid
import Std.Environment as Environment
import Msil.Bridge
import Lyric.Emitter as Emitter

// ─── Helpers ────────────────────────────────────────────────────────────────
func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", Environment.getVarOrDefault("TEMP", Environment.getVarOrDefault("TMP", "/tmp")))
}

func freshTempDir(label: in String): String {
  val root = Path.join(tempBase(), "lyric-msil-proj-" + label + "-" + uuidToString(newUuid()))
  match File.createDir(root) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create temp dir " + root + ": " + IOError.message(e))
  }
  root
}

// Inline `runtimeconfig.json` matching `lyric build`'s convention so
// `dotnet exec` can locate the right framework.  Same shape as
// `lyric-compiler/lyric/cli.l::runtimeConfigJson`.
func runtimeConfigJson(): String {
  "{\n" + "  \"runtimeOptions\": {\n" + "    \"tfm\": \"net10.0\",\n" + "    \"framework\": {\n" +
    "      \"name\": \"Microsoft.NETCore.App\",\n" +
    "      \"version\": \"10.0.0\"\n" +
    "    }\n" +
    "  }\n" +
    "}\n"
}

func writeRuntimeConfig(dllPath: in String): Unit {
  val dir = Path.dirname(dllPath)
  val base = Path.basename(dllPath)
  // Strip ".dll" — basename is the file name including the extension.
  val stem = if base.endsWith(".dll") { base.substring(0, base.length - 4) } else { base }
  val cfgPath = Path.join(dir, stem + ".runtimeconfig.json")
  match File.writeText(cfgPath, runtimeConfigJson()) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }
}

func cleanup(dir: in String): Unit {
  match File.deleteDirRecursive(dir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }
}

// Build a `ProjectPackagePayload` from `(name, source)`.
func mkPkg(name: in String, source: in String): ProjectPackagePayload {
  ProjectPackagePayload(name = name, source = source)
}

// Compile `packages` into a bundle at `outputPath`, run it under
// `dotnet exec`, and return the captured `CaptureResult`.  Panics with a
// descriptive message if compilation fails, so the caller can focus on
// asserting on the runtime behaviour.
func compileAndRun(
  label: in String, packages: in List[ProjectPackagePayload], assemblyName: in String
): Capture.CaptureResult {
  val dir = freshTempDir(label)
  val dllPath = Path.join(dir, assemblyName + ".dll")
  val stdlibSources: List[String] = newList()
  // empty: the test sources don't import stdlib types
  val ok = compileProjectToMsil(packages, assemblyName, dllPath, stdlibSources)
  if not ok {
    cleanup(dir)
    panic(label + ": compileProjectToMsil returned false")
  }
  writeRuntimeConfig(dllPath)
  val args: List[String] = newList()
  args.add("exec")
  args.add(dllPath)
  val result = Capture.runCaptureWithDiagnostics("dotnet", args, "")
  cleanup(dir)
  result
}

// ─── Tests ──────────────────────────────────────────────────────────────────
// Two independent packages bundle into one PE.  The library package
// defines a pub func; the consumer is a single-package program with main
// that prints a literal.  Pins the row-numbering refactor: package B's
// `addPackageTokens` resumes from where package A left off.
func testTwoIndependentPackagesBundle(): Unit {
  val packages: List[ProjectPackagePayload] = newList()
  packages.add(mkPkg("TwoIndep.Lib", "package TwoIndep.Lib\n" + "\n" + "pub func doubled(x: in Int): Int { x + x }\n"))
  packages.add(
    mkPkg("TwoIndep.App", "package TwoIndep.App\n" + "\n" + "func main(): Unit {\n" + "  println(7)\n" + "}\n")
  )
  val result = compileAndRun("two-indep", packages, "TwoIndep")
  assertEqualInt(result.exitCode, 0, "two_independent_packages_bundle: exit 0 expected (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "7", "two_independent_packages_bundle: stdout matches expected")
}

// First package contributes a record + func, the second is a plain
// `main`-bearing program.  Pins that pkg B's func tokens land at the
// correct MethodDef row after pkg A's record ctor row.
func testFirstPackageWithRecordDoesNotDisturbSecond(): Unit {
  val packages: List[ProjectPackagePayload] = newList()
  packages.add(
    mkPkg(
      "RowOffset.A",
      "package RowOffset.A\n" + "\n" + "pub record Point { x: Int }\n" + "\n" + "pub func makeOne(): Int { 1 }\n"
    )
  )
  packages.add(
    mkPkg("RowOffset.B", "package RowOffset.B\n" + "\n" + "func main(): Unit {\n" + "  println(42)\n" + "}\n")
  )
  val result = compileAndRun("rowoffset", packages, "RowOffset")
  assertEqualInt(
    result.exitCode,
    0,
    "first_package_with_record_does_not_disturb_second: exit 0 (stderr=" + result.stderr + ")"
  )
  assertEqual(
    Str.trim(result.stdout),
    "42",
    "first_package_with_record_does_not_disturb_second: stdout matches expected"
  )
}

// Cross-package FUNCTION call (Phase 2 of #1183).  Consumer imports the
// library and calls its pub func by simple name.
func testCrossPackageQualifiedCall(): Unit {
  val packages: List[ProjectPackagePayload] = newList()
  packages.add(mkPkg("XPkgCall.Lib", "package XPkgCall.Lib\n" + "\n" + "pub func doubled(x: in Int): Int { x + x }\n"))
  packages.add(
    mkPkg(
      "XPkgCall.App",
      "package XPkgCall.App\n" + "\n" + "import XPkgCall.Lib\n" + "\n" + "func main(): Unit {\n" +
        "  println(doubled(21))\n" +
        "}\n"
    )
  )
  val result = compileAndRun("xpkgcall", packages, "XPkgCall")
  assertEqualInt(result.exitCode, 0, "cross_package_qualified_call: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "42", "cross_package_qualified_call: stdout matches expected")
}

// Chained cross-package Int calls (Phase 2 of #1183).
func testCrossPackageChainedIntCalls(): Unit {
  val packages: List[ProjectPackagePayload] = newList()
  packages.add(
    mkPkg(
      "XPkgChain.Lib",
      "package XPkgChain.Lib\n" + "\n" + "pub func triple(x: in Int): Int { x + x + x }\n" + "\n" +
        "pub func addOne(x: in Int): Int { x + 1 }\n"
    )
  )
  packages.add(
    mkPkg(
      "XPkgChain.App",
      "package XPkgChain.App\n" + "\n" + "import XPkgChain.Lib\n" + "\n" + "func main(): Unit {\n" +
        "  println(addOne(triple(13)))\n" +
        "}\n"
    )
  )
  val result = compileAndRun("xpkgchain", packages, "XPkgChain")
  assertEqualInt(result.exitCode, 0, "cross_package_chained_int_calls: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "40", "cross_package_chained_int_calls: stdout matches expected")
}

// Cross-package RECORD value round-trip (Phase 3 of #1183).
// Pkg A defines a `pub record Point` plus pub funcs that produce and
// consume one; pkg B imports A, binds a Point local from `makePoint`,
// and passes it back to `pointX` for field-access on pkg A's side.
// Two earlier bugs surfaced before this ran green:
//   1. `bufMsilType` wrote only the 1-byte CLASS prefix for `MClass(_)`
//      without the required TypeDefOrRef token (raised
//      `BadImageFormatException` when the CLR parsed the method
//      signature).  Now degraded to ELEMENT_TYPE_OBJECT (0x1C).
//   2. `lowerRecordMsil` set `flags = 0x0001` (PrivateScope) on record
//      fields instead of `0x0006` (Public), so cross-package `ldfld`
//      raised `FieldAccessException`.
func testCrossPackageRecordValueRoundTrip(): Unit {
  val packages: List[ProjectPackagePayload] = newList()
  packages.add(
    mkPkg(
      "XPkgRec.Lib",
      "package XPkgRec.Lib\n" + "\n" + "pub record Point { x: Int }\n" + "\n" +
        "pub func makePoint(v: in Int): Point { Point(x = v) }\n" +
        "\n" +
        "pub func pointX(p: in Point): Int { p.x }\n"
    )
  )
  packages.add(
    mkPkg(
      "XPkgRec.App",
      "package XPkgRec.App\n" + "\n" + "import XPkgRec.Lib\n" + "\n" + "func main(): Unit {\n" +
        "  val p = makePoint(7)\n" +
        "  println(pointX(p))\n" +
        "}\n"
    )
  )
  val result = compileAndRun("xpkgrec", packages, "XPkgRec")
  assertEqualInt(result.exitCode, 0, "cross_package_record_value_round_trip: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "7", "cross_package_record_value_round_trip: stdout matches expected")
}

// Cross-package union construction + match (#1183 codegen port).
// Pkg A defines a generic union; pkg B imports A, constructs both
// cases, and pattern-matches each.  Exercises three changes together:
//   1. `unionCaseCtorByName` lets `Some(value=X)` / `None` resolve
//      to pkg A's ctor tokens by simple name.
//   2. The construction returns the PARENT UNION type so the local
//      variable's slot type matches what the match-arm `isinst`
//      tests against (`<union>$<case>`).
//   3. `lowerPatternTestMsil` now resolves the case's actual TypeDef
//      row via `findTypeDefRowByName` instead of falling back to
//      `trObject` — without that, every `isinst` returned the same
//      reference and the FIRST pattern arm always matched regardless
//      of the actual case.
func testCrossPackageUnionConstructAndMatch(): Unit {
  val packages: List[ProjectPackagePayload] = newList()
  packages.add(
    mkPkg(
      "XPkgUnion.Lib",
      "package XPkgUnion.Lib\n" + "\n" + "pub union Status {\n" + "  case Active\n" + "  case Inactive\n" + "}\n"
    )
  )
  packages.add(
    mkPkg(
      "XPkgUnion.App",
      "package XPkgUnion.App\n" + "import XPkgUnion.Lib\n" + "\n" + "func describe(s: in Status): String {\n" +
        "  match s {\n" +
        "    case Active()   -> \"active\"\n" +
        "    case Inactive() -> \"inactive\"\n" +
        "  }\n" +
        "}\n" +
        "\n" +
        "func main(): Unit {\n" +
        "  val a = Active()\n" +
        "  val i = Inactive()\n" +
        "  println(describe(a))\n" +
        "  println(describe(i))\n" +
        "}\n"
    )
  )
  val result = compileAndRun("xpkg-union", packages, "XPkgUnion")
  assertEqualInt(result.exitCode, 0, "cross_package_union_construct_and_match: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(
    Str.trim(result.stdout),
    "active\ninactive",
    "cross_package_union_construct_and_match: both arms hit the correct case"
  )
}

// ─── Phase 4: in-process routing through Lyric.Emitter.emitProject ──────────
//
// The tests above call Msil.Bridge.compileProjectToMsil directly.  Phase 4
// (#1183) makes Lyric.Emitter.emitProject route DOTNET multi-package builds
// through the same in-process bridge instead of shelling out to
// `lyric --internal-project-build`.  These tests cover the routing layer:
// they build a `Lyric.Emitter.EmitProjectRequest`, hand it to
// `emitProject`, and assert the produced DLL runs and prints the
// expected value.  No restored deps, no active features — those still
// route through the subprocess fallback (Phase 5).
func runEmitProject(
  label: in String, projectPkgs: in List[Emitter.ProjectPackage], assemblyName: in String
): Capture.CaptureResult {
  val dir = freshTempDir(label)
  val dllPath = Path.join(dir, assemblyName + ".dll")
  val req = Emitter.EmitProjectRequest(
    packages = projectPkgs,
    assemblyName = assemblyName,
    outputPath = dllPath,
    target = Emitter.Dotnet,
    restoredDllPaths = newList(),
    activeFeatures = newList(),
    declaredFeatures = newList(),
    packageVersion = ""
  )
  val result = Emitter.emitProject(req)
  match result.outputPath {
    case None -> {
      cleanup(dir)
      panic(label + ": emitProject produced no output (diagnostics on stderr)")
    }
    case Some(_) -> ()
  }
  writeRuntimeConfig(dllPath)
  val args: List[String] = newList()
  args.add("exec")
  args.add(dllPath)
  val captured = Capture.runCaptureWithDiagnostics("dotnet", args, "")
  cleanup(dir)
  captured
}

func mkProjectPkg(name: in String, source: in String): Emitter.ProjectPackage {
  val srcs: List[String] = newList()
  srcs.add(source)
  Emitter.ProjectPackage(name = name, sources = srcs)
}

// Lyric.Emitter.emitProject with two independent packages: pins the
// in-process routing path (canInProc=true) end-to-end.
func testEmitProjectInProcessIndependent(): Unit {
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(
    mkProjectPkg(
      "EmitProjInProc.Lib",
      "package EmitProjInProc.Lib\n" + "\n" + "pub func tripled(x: in Int): Int { x + x + x }\n"
    )
  )
  pkgs.add(
    mkProjectPkg(
      "EmitProjInProc.App",
      "package EmitProjInProc.App\n" + "\n" + "func main(): Unit {\n" + "  println(11)\n" + "}\n"
    )
  )
  val result = runEmitProject("emitproj-indep", pkgs, "EmitProjInProc")
  assertEqualInt(result.exitCode, 0, "emit_project_in_process_independent: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "11", "emit_project_in_process_independent: stdout matches expected")
}

// Lyric.Emitter.emitProject routes a cross-package call through the
// in-process bridge — same Phase 2 scenario, now via the front door
// instead of the bridge directly.
func testEmitProjectInProcessCrossPackageCall(): Unit {
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(
    mkProjectPkg(
      "EmitProjXPkg.Lib",
      "package EmitProjXPkg.Lib\n" + "\n" + "pub func quadrupled(x: in Int): Int { x + x + x + x }\n"
    )
  )
  pkgs.add(
    mkProjectPkg(
      "EmitProjXPkg.App",
      "package EmitProjXPkg.App\n" + "\n" + "import EmitProjXPkg.Lib\n" + "\n" + "func main(): Unit {\n" +
        "  println(quadrupled(11))\n" +
        "}\n"
    )
  )
  val result = runEmitProject("emitproj-xpkg", pkgs, "EmitProjXPkg")
  assertEqualInt(
    result.exitCode,
    0,
    "emit_project_in_process_cross_package_call: exit 0 (stderr=" + result.stderr + ")"
  )
  assertEqual(Str.trim(result.stdout), "44", "emit_project_in_process_cross_package_call: stdout matches expected")
}

// ─── @cfg feature erasure via the in-process bridge ────────────────────────
//
// These exercise the Phase 4 cfg-erasure plumbing: `emitProject` no longer
// shells out when `activeFeatures` is non-empty (#1183).  The bridge now
// runs `Lyric.Cfg.applyCfgErasure` between parse and typecheck so items
// annotated `@cfg(feature = "X")` are dropped when X is absent from the
// active set.
func runEmitProjectWithFeatures(
  label: in String,
  projectPkgs: in List[Emitter.ProjectPackage],
  assemblyName: in String,
  features: in List[String],
  declared: in List[String],
): Capture.CaptureResult {
  val dir = freshTempDir(label)
  val dllPath = Path.join(dir, assemblyName + ".dll")
  val req = Emitter.EmitProjectRequest(
    packages = projectPkgs,
    assemblyName = assemblyName,
    outputPath = dllPath,
    target = Emitter.Dotnet,
    restoredDllPaths = newList(),
    activeFeatures = features,
    declaredFeatures = declared,
    packageVersion = ""
  )
  val result = Emitter.emitProject(req)
  match result.outputPath {
    case None -> {
      cleanup(dir)
      panic(label + ": emitProject produced no output (diagnostics on stderr)")
    }
    case Some(_) -> ()
  }
  writeRuntimeConfig(dllPath)
  val args: List[String] = newList()
  args.add("exec")
  args.add(dllPath)
  val captured = Capture.runCaptureWithDiagnostics("dotnet", args, "")
  cleanup(dir)
  captured
}

// Feature INACTIVE -> the gated function is erased entirely, so `main`
// falls back to the unconditional branch.
func testCfgErasureFeatureInactive(): Unit {
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(
    mkProjectPkg(
      "CfgErase.App",
      "package CfgErase.App\n" + "\n" + "@cfg(feature = \"experimental\")\n" +
        "pub func greeting(): String { \"experimental\" }\n" +
        "\n" +
        "pub func greetingFallback(): String { \"stable\" }\n" +
        "\n" +
        "func main(): Unit {\n" +
        "  println(greetingFallback())\n" +
        "}\n"
    )
  )
  val empty: List[String] = newList()
  val declared: List[String] = newList()
  declared.add("experimental")
  val result = runEmitProjectWithFeatures("cfg-inactive", pkgs, "CfgEraseInactive", empty, declared)
  assertEqualInt(result.exitCode, 0, "cfg_erasure_feature_inactive: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "stable", "cfg_erasure_feature_inactive: stdout matches expected")
}

// Feature ACTIVE -> the gated function is kept; `main` calls it.
func testCfgErasureFeatureActive(): Unit {
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(
    mkProjectPkg(
      "CfgKeep.App",
      "package CfgKeep.App\n" + "\n" + "@cfg(feature = \"experimental\")\n" +
        "pub func greeting(): String { \"experimental\" }\n" +
        "\n" +
        "func main(): Unit {\n" +
        "  println(greeting())\n" +
        "}\n"
    )
  )
  val active: List[String] = newList()
  active.add("experimental")
  val declared: List[String] = newList()
  declared.add("experimental")
  val result = runEmitProjectWithFeatures("cfg-active", pkgs, "CfgEraseActive", active, declared)
  assertEqualInt(result.exitCode, 0, "cfg_erasure_feature_active: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "experimental", "cfg_erasure_feature_active: stdout matches expected")
}

// Multiple @cfg on the same item AND together: item is kept only when
// ALL feature predicates hold.  Here `gated` requires both `alpha` and
// `beta`; activating only `alpha` erases it.
func testCfgErasureAndSemantics(): Unit {
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(
    mkProjectPkg(
      "CfgAnd.App",
      "package CfgAnd.App\n" + "\n" + "@cfg(feature = \"alpha\")\n" + "@cfg(feature = \"beta\")\n" +
        "pub func gated(): String { \"both\" }\n" +
        "\n" +
        "pub func ungated(): String { \"one\" }\n" +
        "\n" +
        "func main(): Unit {\n" +
        "  println(ungated())\n" +
        "}\n"
    )
  )
  val active: List[String] = newList()
  active.add("alpha")
  val declared: List[String] = newList()
  declared.add("alpha")
  declared.add("beta")
  val result = runEmitProjectWithFeatures("cfg-and", pkgs, "CfgAnd", active, declared)
  assertEqualInt(result.exitCode, 0, "cfg_erasure_and_semantics: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "one", "cfg_erasure_and_semantics: stdout matches expected")
}

// Build a `compileProjectToMsil`-style project that should produce
// diagnostics rather than a runnable output, and return the bridge's
// pass/fail signal plus the captured diagnostics surface so tests can
// assert on F0012/F0013 firing.  Uses `compileProjectToMsilWithFeatures`
// directly (not through `emitProject`) because we want the raw bool
// return.  When the bridge returns false, the diagnostic was an error;
// true means warnings only (the build still succeeded).
func compileAndGetSucceeded(
  label: in String,
  packages: in List[ProjectPackagePayload],
  assemblyName: in String,
  active: in List[String],
  declared: in List[String],
): Bool {
  val dir = freshTempDir(label)
  val dllPath = Path.join(dir, assemblyName + ".dll")
  val stdlibSources: List[String] = newList()
  val ok = compileProjectToMsilWithFeatures(packages, assemblyName, dllPath, stdlibSources, active, declared)
  cleanup(dir)
  ok
}

// F0012 fires for a malformed @cfg (e.g. literal argument instead of
// `feature = "X"`).  This is an ERROR diagnostic, so the bridge
// returns false.
func testCfgErasureF0012Malformed(): Unit {
  val pkgs: List[ProjectPackagePayload] = newList()
  pkgs.add(
    mkPkg(
      "CfgMalformed.App",
      "package CfgMalformed.App\n" + "\n" + "@cfg(\"experimental\")\n" + "pub func gated(): String { \"x\" }\n" + "\n" +
        // `main` body deliberately compiles cleanly — the test gates on
        // the F0012 abort BEFORE typecheck runs.  Earlier versions used
        // `println(0)` (Int, not String) which would have been a latent
        // type error masked by the abort (#1233).
        "func main(): Unit { println(\"unreachable\") }\n"
    )
  )
  val empty: List[String] = newList()
  val ok = compileAndGetSucceeded("cfg-f0012", pkgs, "CfgF0012", empty, empty)
  assertTrue(not ok, "cfg_erasure_f0012_malformed: bridge should reject malformed @cfg")
}

// F0013 fires when a feature reference is absent from the manifest's
// declared set (typo guard).  F0013 is a WARNING — the build still
// succeeds (bridge returns true); the diagnostic surfaces the typo to
// the user without erasing or breaking compilation.
//
// Erasure still happens (the feature isn't in `active`), so we use a
// fallback function to keep `main` runnable; we assert the build
// succeeds and produces output.
//
// Known gap (#1234): this test asserts only that the build succeeded.
// It does NOT verify F0013 actually fired — a regression that silently
// dropped the warning would still pass.  The bridge writes diagnostics
// directly to stderr via `reportAndAbort`; capturing them for assertion
// needs a `Result`-shaped variant of `compileProjectToMsilWithFeatures`
// that surfaces the diagnostic list to callers.
func testCfgErasureF0013Typo(): Unit {
  val pkgs: List[ProjectPackagePayload] = newList()
  pkgs.add(
    mkPkg(
      "CfgTypo.App",
      "package CfgTypo.App\n" + "\n" + "@cfg(feature = \"experimntal\")\n" + "pub func gated(): String { \"x\" }\n" +
        "\n" +
        "pub func fallback(): String { \"fallback\" }\n" +
        "\n" +
        "func main(): Unit { println(fallback()) }\n"
    )
  )
  val empty: List[String] = newList()
  val declared: List[String] = newList()
  declared.add("experimental")
  val ok = compileAndGetSucceeded("cfg-f0013", pkgs, "CfgF0013", empty, declared)
  assertTrue(ok, "cfg_erasure_f0013_typo: warning should not fail the build")
}

// File-level `@cfg` (annotation above the `package` declaration)
// erases every item in the file when the feature is inactive.  Pkg A
// is fully erased; Pkg B's `main` runs unaffected.
func testCfgErasureFileLevelErasesEntireFile(): Unit {
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(
    mkProjectPkg(
      "CfgFile.Lib",
      "@cfg(feature = \"unused\")\n" + "package CfgFile.Lib\n" + "\n" + "pub func neverCompiled(): Int { 0 }\n"
    )
  )
  pkgs.add(
    mkProjectPkg("CfgFile.App", "package CfgFile.App\n" + "\n" + "func main(): Unit { println(\"survived\") }\n")
  )
  val empty: List[String] = newList()
  val declared: List[String] = newList()
  declared.add("unused")
  val result = runEmitProjectWithFeatures("cfg-file-erase", pkgs, "CfgFileErase", empty, declared)
  assertEqualInt(result.exitCode, 0, "cfg_erasure_file_level: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "survived", "cfg_erasure_file_level: stdout matches expected")
}

// ─── Phase A.4: restored-dep wiring crash-safety smoke test ────────────────
//
// Confirms that the `emitProject` restored-dep wiring doesn't crash
// when handed a non-existent DLL path — the load fails cleanly and
// the emitter returns an `EmitResult` carrying a `DllMissing`
// diagnostic with no `outputPath`.  Before the subprocess fallback
// retirement this used to bounce through the F# subprocess as a
// secondary attempt; now the in-process loader's error is the
// authoritative result (the slice 3 E2E test proves the in-process
// pipeline works end-to-end, so falling back was both unnecessary
// and a debuggability hazard — surfacing the original error wins).
func testRestoredDepWiringNoCrash(): Unit {
  val tmpDir = freshTempDir("restored-wiring")
  val consumerPkgs: List[Emitter.ProjectPackage] = newList()
  consumerPkgs.add(
    mkProjectPkg(
      "RestoredFallbackApp",
      "package RestoredFallbackApp\n" + "\n" + "func main(): Unit {\n" + "  println(\"fallback ok\")\n" + "}\n"
    )
  )
  val consumerDll = Path.join(tmpDir, "RestoredFallbackApp.dll")
  val restoredDlls: List[String] = newList()
  // Non-existent path: in-process loader returns `DllMissing`, which
  // the emitter surfaces directly via `failResult` (no subprocess
  // bounce since slice 3).  We expect `outputPath = None` and NO panic.
  restoredDlls.add("RestoredFallbackLib\t" + Path.join(tmpDir, "missing.dll"))
  val req = Emitter.EmitProjectRequest(
    packages = consumerPkgs,
    assemblyName = "RestoredFallbackApp",
    outputPath = consumerDll,
    target = Emitter.Dotnet,
    restoredDllPaths = restoredDlls,
    activeFeatures = newList(),
    declaredFeatures = newList(),
    packageVersion = ""
  )
  val result = Emitter.emitProject(req)
  // Expected: in-process loader reports DllMissing, emitter surfaces
  // via `failResult`, `outputPath = None`.
  match result.outputPath {
    case None -> ()
    // expected
    case Some(_) -> {
      cleanup(tmpDir)
      panic("restored_wiring: missing DLL must produce no output")
    }
  }
  // Also pin that some diagnostic mentions the missing DLL path
  // (#1381) so a regression that swallows the failResult message
  // would surface here.
  var sawPath = false
  var di = 0
  while di < result.diagnostics.count {
    if Str.contains(result.diagnostics[di].message, "missing.dll") {
      sawPath = true
    }
    di = di + 1
  }
  assertTrue(sawPath, "restored_wiring: a diagnostic must mention the missing DLL path")
  cleanup(tmpDir)
}

// Regression test for #1378's primary reproduction symptom.  A user
// package that imports another in-bundle package under an alias
// (`import X as Y`) and calls a function via the alias (`Y.fn(...)`)
// must typecheck without `T0020 unknown name 'Y'`.  The self-hosted
// typechecker doesn't track import aliases natively; `Lyric.AliasRewriter`
// runs between parse and typecheck to collapse `Y.fn(...)` to bare
// `fn(...)`, matching the F# emitter's `AliasRewriter` pre-pass.
func testEmitProjectAliasedCrossPackageCall(): Unit {
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(
    mkProjectPkg(
      "AliasXPkg.Lib",
      "package AliasXPkg.Lib\n" + "\n" + "pub func quintupled(x: in Int): Int { x + x + x + x + x }\n"
    )
  )
  pkgs.add(
    mkProjectPkg(
      "AliasXPkg.App",
      "package AliasXPkg.App\n" + "\n" + "import AliasXPkg.Lib as Lib\n" + "\n" + "func main(): Unit {\n" +
        "  println(Lib.quintupled(8))\n" +
        "}\n"
    )
  )
  val result = runEmitProject("alias-xpkg", pkgs, "AliasXPkg")
  assertEqualInt(result.exitCode, 0, "alias_cross_package_call: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "40", "alias_cross_package_call: stdout matches expected")
}

// Regression test for #1378's per-package symbol-table filtering
// follow-up.  Two unrelated packages each define a record called
// `Helper` — neither imports the other.  Before the per-package
// refactor, the bridge flat-merged every prior package's items into
// the next package's typecheck, so the second `Helper` registration
// hit T0001 'duplicate name' and aborted the build.  With per-package
// filtering, each package's typecheck sees only its declared imports
// (here: none from the bundle), so the name collision is invisible.
func testPerPackageIsolationDuplicateName(): Unit {
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(mkProjectPkg("PerPkgIso.Alpha", "package PerPkgIso.Alpha\n" + "\n" + "pub record Helper { value: Int }\n"))
  pkgs.add(
    mkProjectPkg(
      "PerPkgIso.Beta",
      "package PerPkgIso.Beta\n" + "\n" + "pub record Helper { value: Int }\n" + "\n" +
        "func main(): Unit { println(7) }\n"
    )
  )
  val result = runEmitProject("perpkg-iso", pkgs, "PerPkgIso")
  assertEqualInt(result.exitCode, 0, "per_package_isolation_duplicate_name: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "7", "per_package_isolation_duplicate_name: stdout matches expected")
}

// Regression test for #1435.  When the same package source appears in
// BOTH `packages` (as an in-bundle user package) AND `stdlibSources`
// (as a pre-loaded base), `perPackageImportedItems` used to call
// `addBundleClosure` for that package even though its items were already
// in `baseItems`.  That caused every type defined in the shared package
// (e.g., a generic union like `Wrap[T]`) to be registered TWICE in the
// symbol table with distinct TypeIds, corrupting the type-variable
// resolution for subsequent packages.  `var i = 0; while i <= n - k`
// loops in an importing package then hit T0033 because `i` resolved to
// `TyVar("")` instead of `TyPrim(PtInt)`.
//
// The fix: `addBundleClosure` skips any package whose name already
// appears in the stdlib-packages map (`baseNames`), preventing the
// double registration.  This test pins that fix by passing the same
// source as both a `packages` entry (Ix1435.Core) and as a
// `stdlibSources` entry, then asserting that a consumer package whose
// body contains the exact failing loop shape compiles and runs correctly.
func testStdlibSelfBuildNoDuplicateTypeVarCorruption(): Unit {
  // Shared source: appears as BOTH packages["Ix1435.Core"] AND stdlibSources[0].
  // The generic union mirrors Std.Core's Option[T]/Result[T,E] pattern
  // whose double-registration triggered the TyVar("") corruption.
  val sharedSrc = "package Ix1435.Core\n" + "\n" + "pub generic[T] union Wrap {\n" + "  case Wrapped(value: T)\n" +
    "  case Empty\n" +
    "}\n" +
    "\n" +
    "pub func wrapInt(x: in Int): Wrap[Int] { Wrapped(value = x) }\n"
  val consumerSrc = "package Ix1435.App\n" + "\n" + "import Ix1435.Core\n" + "\n" +
    "// Same shape as Std.Regex.isTimeout: loop variable below a subtracted\n" +
    "// upper bound.  Before the fix this produced T0033 because the LHS of\n" +
    "// `<=` resolved to TyVar(\"\") instead of TyPrim(PtInt).\n" +
    "func countPositions(len: in Int, needle: in Int): Int {\n" +
    "  var i = 0\n" +
    "  while i <= len - needle {\n" +
    "    i = i + 1\n" +
    "  }\n" +
    "  i\n" +
    "}\n" +
    "\n" +
    "func main(): Unit {\n" +
    "  println(countPositions(10, 3))\n" +
    "}\n"
  val dir = freshTempDir("ix1435")
  val dllPath = Path.join(dir, "Ix1435.dll")
  val packages: List[ProjectPackagePayload] = newList()
  packages.add(mkPkg("Ix1435.Core", sharedSrc))
  packages.add(mkPkg("Ix1435.App", consumerSrc))
  val stdlibSources: List[String] = newList()
  stdlibSources.add(sharedSrc)
  // same source — the overlap that caused #1435
  val ok = compileProjectToMsil(packages, "Ix1435", dllPath, stdlibSources)
  if not ok {
    cleanup(dir)
    panic("ix1435_no_duplicate_type_var_corruption: compile failed (T0033 regression?)")
  }
  writeRuntimeConfig(dllPath)
  val args: List[String] = newList()
  args.add("exec")
  args.add(dllPath)
  val result = Capture.runCaptureWithDiagnostics("dotnet", args, "")
  cleanup(dir)
  assertEqualInt(result.exitCode, 0, "ix1435_no_duplicate_type_var_corruption: exit 0 (stderr=" + result.stderr + ")")
  // countPositions(10, 3): i increments 0..8 while i <= 7, result = 8
  assertEqual(Str.trim(result.stdout), "8", "ix1435_no_duplicate_type_var_corruption: stdout=8")
}

func main(): Int {
  testTwoIndependentPackagesBundle()
  testFirstPackageWithRecordDoesNotDisturbSecond()
  testCrossPackageQualifiedCall()
  testCrossPackageChainedIntCalls()
  testCrossPackageRecordValueRoundTrip()
  testEmitProjectInProcessIndependent()
  testEmitProjectInProcessCrossPackageCall()
  testEmitProjectAliasedCrossPackageCall()
  testPerPackageIsolationDuplicateName()
  testCrossPackageUnionConstructAndMatch()
  testCfgErasureFeatureInactive()
  testCfgErasureFeatureActive()
  testCfgErasureAndSemantics()
  testCfgErasureF0012Malformed()
  testCfgErasureF0013Typo()
  testCfgErasureFileLevelErasesEntireFile()
  testRestoredDepWiringNoCrash()
  testStdlibSelfBuildNoDuplicateTypeVarCorruption()
  println("msil-project-bridge tests: ok")
  return 0
}
