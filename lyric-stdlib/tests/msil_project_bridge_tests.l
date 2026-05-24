// lyric-compiler/tests/msil_project_bridge_tests.l — end-to-end tests for
// the self-hosted multi-package MSIL bridge (`Msil.Bridge.compileProjectToMsil`).
//
// Each test bundles multiple Lyric packages into one PE via the in-process
// self-hosted pipeline, runs the produced DLL via `dotnet exec`, and
// asserts on stdout.  Mirrors the F# `SelfHostedMsilProjectBridgeTests.fs`
// that this file replaces (#1183: tests live in Lyric, not F#, per
// CLAUDE.md's "F# surface is frozen" policy).
//
// Discovery: a thin Expecto runner shim
// (`bootstrap/tests/Lyric.Cli.Tests/MsilProjectLyricTests.fs`) compiles
// this file + runs it; the shim only carries the discovery / process
// plumbing, never any test logic.

package Lyric.Tests.MsilProjectBridge

import Std.Core
import Std.Collections
import Std.Errors
import Std.File as File
import Std.String as Str      // before Path so Path.join/2 wins over Str.join/2
import Std.Path as Path
import Std.ProcessCapture as Capture
import Std.Testing
import Std.Uuid
import Std.Environment as Environment
import Msil.Bridge
import Lyric.Emitter as Emitter

// ─── Helpers ────────────────────────────────────────────────────────────────

func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR",
    Environment.getVarOrDefault("TEMP",
      Environment.getVarOrDefault("TMP", "/tmp")))
}

func freshTempDir(label: in String): String {
  val root = Path.join(tempBase(), "lyric-msil-proj-" + label + "-" + uuidToString(newUuid()))
  match File.createDir(root) {
    case Ok(_)  -> ()
    case Err(e) -> panic("cannot create temp dir " + root + ": " + IOError.message(e))
  }
  root
}

// Inline `runtimeconfig.json` matching `lyric build`'s convention so
// `dotnet exec` can locate the right framework.  Same shape as
// `lyric-compiler/lyric/cli.l::runtimeConfigJson`.
func runtimeConfigJson(): String {
  "{\n" +
  "  \"runtimeOptions\": {\n" +
  "    \"tfm\": \"net10.0\",\n" +
  "    \"framework\": {\n" +
  "      \"name\": \"Microsoft.NETCore.App\",\n" +
  "      \"version\": \"10.0.0\"\n" +
  "    }\n" +
  "  }\n" +
  "}\n"
}

func writeRuntimeConfig(dllPath: in String): Unit {
  val dir  = Path.dirname(dllPath)
  val base = Path.basename(dllPath)
  // Strip ".dll" — basename is the file name including the extension.
  val stem = if base.endsWith(".dll") { base.substring(0, base.length - 4) }
             else                     { base }
  val cfgPath = Path.join(dir, stem + ".runtimeconfig.json")
  match File.writeText(cfgPath, runtimeConfigJson()) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }
}

func cleanup(dir: in String): Unit {
  match File.deleteDirRecursive(dir) { case Ok(_) -> () case Err(_) -> () }
}

// Build a `ProjectPackagePayload` from `(name, source)`.
func mkPkg(name: in String, source: in String): ProjectPackagePayload {
  ProjectPackagePayload(name = name, source = source)
}

// Compile `packages` into a bundle at `outputPath`, run it under
// `dotnet exec`, and return the captured `CaptureResult`.  Panics with a
// descriptive message if compilation fails, so the caller can focus on
// asserting on the runtime behaviour.
func compileAndRun(label: in String, packages: in List[ProjectPackagePayload], assemblyName: in String): Capture.CaptureResult {
  val dir     = freshTempDir(label)
  val dllPath = Path.join(dir, assemblyName + ".dll")
  val stdlibSources: List[String] = newList()  // empty: the test sources don't import stdlib types
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
  packages.add(mkPkg("TwoIndep.Lib",
    "package TwoIndep.Lib\n" +
    "\n" +
    "pub func doubled(x: in Int): Int { x + x }\n"))
  packages.add(mkPkg("TwoIndep.App",
    "package TwoIndep.App\n" +
    "\n" +
    "func main(): Unit {\n" +
    "  println(7)\n" +
    "}\n"))
  val result = compileAndRun("two-indep", packages, "TwoIndep")
  assertEqualInt(result.exitCode, 0,
    "two_independent_packages_bundle: exit 0 expected (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "7",
    "two_independent_packages_bundle: stdout matches expected")
}

// First package contributes a record + func, the second is a plain
// `main`-bearing program.  Pins that pkg B's func tokens land at the
// correct MethodDef row after pkg A's record ctor row.
func testFirstPackageWithRecordDoesNotDisturbSecond(): Unit {
  val packages: List[ProjectPackagePayload] = newList()
  packages.add(mkPkg("RowOffset.A",
    "package RowOffset.A\n" +
    "\n" +
    "pub record Point { x: Int }\n" +
    "\n" +
    "pub func makeOne(): Int { 1 }\n"))
  packages.add(mkPkg("RowOffset.B",
    "package RowOffset.B\n" +
    "\n" +
    "func main(): Unit {\n" +
    "  println(42)\n" +
    "}\n"))
  val result = compileAndRun("rowoffset", packages, "RowOffset")
  assertEqualInt(result.exitCode, 0,
    "first_package_with_record_does_not_disturb_second: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "42",
    "first_package_with_record_does_not_disturb_second: stdout matches expected")
}

// Cross-package FUNCTION call (Phase 2 of #1183).  Consumer imports the
// library and calls its pub func by simple name.
func testCrossPackageQualifiedCall(): Unit {
  val packages: List[ProjectPackagePayload] = newList()
  packages.add(mkPkg("XPkgCall.Lib",
    "package XPkgCall.Lib\n" +
    "\n" +
    "pub func doubled(x: in Int): Int { x + x }\n"))
  packages.add(mkPkg("XPkgCall.App",
    "package XPkgCall.App\n" +
    "\n" +
    "import XPkgCall.Lib\n" +
    "\n" +
    "func main(): Unit {\n" +
    "  println(doubled(21))\n" +
    "}\n"))
  val result = compileAndRun("xpkgcall", packages, "XPkgCall")
  assertEqualInt(result.exitCode, 0,
    "cross_package_qualified_call: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "42",
    "cross_package_qualified_call: stdout matches expected")
}

// Chained cross-package Int calls (Phase 2 of #1183).
func testCrossPackageChainedIntCalls(): Unit {
  val packages: List[ProjectPackagePayload] = newList()
  packages.add(mkPkg("XPkgChain.Lib",
    "package XPkgChain.Lib\n" +
    "\n" +
    "pub func triple(x: in Int): Int { x + x + x }\n" +
    "\n" +
    "pub func addOne(x: in Int): Int { x + 1 }\n"))
  packages.add(mkPkg("XPkgChain.App",
    "package XPkgChain.App\n" +
    "\n" +
    "import XPkgChain.Lib\n" +
    "\n" +
    "func main(): Unit {\n" +
    "  println(addOne(triple(13)))\n" +
    "}\n"))
  val result = compileAndRun("xpkgchain", packages, "XPkgChain")
  assertEqualInt(result.exitCode, 0,
    "cross_package_chained_int_calls: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "40",
    "cross_package_chained_int_calls: stdout matches expected")
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
  packages.add(mkPkg("XPkgRec.Lib",
    "package XPkgRec.Lib\n" +
    "\n" +
    "pub record Point { x: Int }\n" +
    "\n" +
    "pub func makePoint(v: in Int): Point { Point(x = v) }\n" +
    "\n" +
    "pub func pointX(p: in Point): Int { p.x }\n"))
  packages.add(mkPkg("XPkgRec.App",
    "package XPkgRec.App\n" +
    "\n" +
    "import XPkgRec.Lib\n" +
    "\n" +
    "func main(): Unit {\n" +
    "  val p = makePoint(7)\n" +
    "  println(pointX(p))\n" +
    "}\n"))
  val result = compileAndRun("xpkgrec", packages, "XPkgRec")
  assertEqualInt(result.exitCode, 0,
    "cross_package_record_value_round_trip: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "7",
    "cross_package_record_value_round_trip: stdout matches expected")
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
  packages.add(mkPkg("XPkgUnion.Lib",
    "package XPkgUnion.Lib\n" +
    "\n" +
    "pub union Status {\n" +
    "  case Active\n" +
    "  case Inactive\n" +
    "}\n"))
  packages.add(mkPkg("XPkgUnion.App",
    "package XPkgUnion.App\n" +
    "import XPkgUnion.Lib\n" +
    "\n" +
    "func describe(s: in Status): String {\n" +
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
    "}\n"))
  val result = compileAndRun("xpkg-union", packages, "XPkgUnion")
  assertEqualInt(result.exitCode, 0,
    "cross_package_union_construct_and_match: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "active\ninactive",
    "cross_package_union_construct_and_match: both arms hit the correct case")
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

func runEmitProject(label: in String, projectPkgs: in List[Emitter.ProjectPackage], assemblyName: in String): Capture.CaptureResult {
  val dir     = freshTempDir(label)
  val dllPath = Path.join(dir, assemblyName + ".dll")
  val req = Emitter.EmitProjectRequest(
    packages         = projectPkgs,
    assemblyName     = assemblyName,
    outputPath       = dllPath,
    target           = Emitter.Dotnet,
    restoredDllPaths = newList(),
    activeFeatures   = newList())
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
  pkgs.add(mkProjectPkg("EmitProjInProc.Lib",
    "package EmitProjInProc.Lib\n" +
    "\n" +
    "pub func tripled(x: in Int): Int { x + x + x }\n"))
  pkgs.add(mkProjectPkg("EmitProjInProc.App",
    "package EmitProjInProc.App\n" +
    "\n" +
    "func main(): Unit {\n" +
    "  println(11)\n" +
    "}\n"))
  val result = runEmitProject("emitproj-indep", pkgs, "EmitProjInProc")
  assertEqualInt(result.exitCode, 0,
    "emit_project_in_process_independent: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "11",
    "emit_project_in_process_independent: stdout matches expected")
}

// Lyric.Emitter.emitProject routes a cross-package call through the
// in-process bridge — same Phase 2 scenario, now via the front door
// instead of the bridge directly.
func testEmitProjectInProcessCrossPackageCall(): Unit {
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(mkProjectPkg("EmitProjXPkg.Lib",
    "package EmitProjXPkg.Lib\n" +
    "\n" +
    "pub func quadrupled(x: in Int): Int { x + x + x + x }\n"))
  pkgs.add(mkProjectPkg("EmitProjXPkg.App",
    "package EmitProjXPkg.App\n" +
    "\n" +
    "import EmitProjXPkg.Lib\n" +
    "\n" +
    "func main(): Unit {\n" +
    "  println(quadrupled(11))\n" +
    "}\n"))
  val result = runEmitProject("emitproj-xpkg", pkgs, "EmitProjXPkg")
  assertEqualInt(result.exitCode, 0,
    "emit_project_in_process_cross_package_call: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "44",
    "emit_project_in_process_cross_package_call: stdout matches expected")
}

func main(): Int {
  testTwoIndependentPackagesBundle()
  testFirstPackageWithRecordDoesNotDisturbSecond()
  testCrossPackageQualifiedCall()
  testCrossPackageChainedIntCalls()
  testCrossPackageRecordValueRoundTrip()
  testEmitProjectInProcessIndependent()
  testEmitProjectInProcessCrossPackageCall()
  testCrossPackageUnionConstructAndMatch()
  println("msil-project-bridge tests: ok")
  return 0
}
