//! msil_project_bridge_self_test.l — end-to-end tests for the self-hosted
//! multi-package MSIL bridge (`Msil.Bridge.compileProjectToMsil` /
//! `compileProjectToMsilWithFeatures`).
//!
//! Each test bundles multiple Lyric packages into one PE via the in-process
//! self-hosted pipeline, runs the produced DLL via `dotnet exec`, and
//! asserts on stdout.  Covers Phases 1–3 of the multi-package bridge:
//! independent bundles (Phase 1), cross-package function calls (Phase 2),
//! cross-package record and union round-trips (Phase 3), and cfg-erasure
//! diagnostics (F0012/F0013).
//!
//! Placed in `lyric-compiler/lyric/` (not `lyric-stdlib/tests/`) so it
//! can import `Msil.Bridge` without overflowing the F# bootstrap emitter's
//! transitive-closure limit.  `lyric test` resolves the compiler-package
//! imports from pre-compiled stage-1 bundle DLLs via
//! `Emitter.compilerClosureDllPaths`, so no `LYRIC_LOAD_COMPILER=1`
//! recompile is needed.
//!
//! Run in CI via:
//!   lyric test lyric-compiler/lyric/msil_project_bridge_self_test.l
@test_module
package Lyric.MsilProjectBridgeSelfTest

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
import Msil.Bridge

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

func mkPkg(name: in String, source: in String): ProjectPackagePayload {
  ProjectPackagePayload(name = name, source = source)
}

func compileAndRun(
  label: in String, packages: in List[ProjectPackagePayload], assemblyName: in String
): Capture.CaptureResult {
  val dir = freshTempDir(label)
  val dllPath = Path.join(dir, assemblyName + ".dll")
  val stdlibSources: List[String] = newList()
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

// ─── Phase 1: independent-package bundles ────────────────────────────────────
// Two independent packages bundle into one PE.  Pins the row-numbering
// refactor: package B's `addPackageTokens` resumes from where package A
// left off.
test "two independent packages bundle" {
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
test "first package with record does not disturb second" {
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

// ─── Phase 2: cross-package function calls ────────────────────────────────────
// Cross-package FUNCTION call.  Consumer imports the library and calls
// its pub func by simple name.
test "cross-package qualified call" {
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

// Chained cross-package Int calls.
test "cross-package chained Int calls" {
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

// ─── Phase 3: cross-package record and union round-trips ─────────────────────
// Cross-package RECORD value round-trip.  Pkg A defines a `pub record
// Point` plus pub funcs that produce and consume one; pkg B imports A,
// binds a Point local from `makePoint`, and passes it back to `pointX`
// for field-access on pkg A's side.
test "cross-package record value round-trip" {
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

// Cross-package union construction + match.  Pkg A defines a simple
// union; pkg B imports A, constructs both cases, and pattern-matches each.
test "cross-package union construct and match" {
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

// Parenless nullary case syntax (`case Active` without `()`) must resolve
// to the known nullary union case and produce a correct match (#1223).
test "cross-package union parenless nullary case" {
  val packages: List[ProjectPackagePayload] = newList()
  packages.add(
    mkPkg(
      "XPkgUnionBare.Lib",
      "package XPkgUnionBare.Lib\n" + "\n" + "pub union Light {\n" + "  case On\n" + "  case Off\n" + "}\n"
    )
  )
  packages.add(
    mkPkg(
      "XPkgUnionBare.App",
      "package XPkgUnionBare.App\n" + "import XPkgUnionBare.Lib\n" + "\n" + "func describe(s: in Light): String {\n" +
        "  match s {\n" +
        "    case On  -> \"on\"\n" +
        "    case Off -> \"off\"\n" +
        "  }\n" +
        "}\n" +
        "\n" +
        "func main(): Unit {\n" +
        "  val a = On()\n" +
        "  val b = Off()\n" +
        "  println(describe(a))\n" +
        "  println(describe(b))\n" +
        "}\n"
    )
  )
  val result = compileAndRun("xpkg-union-bare", packages, "XPkgUnionBare")
  assertEqualInt(result.exitCode, 0, "cross_package_union_parenless_case: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(
    Str.trim(result.stdout),
    "on\noff",
    "cross_package_union_parenless_case: bare-name case arms match correctly"
  )
}

// `registerRestoredRecordCtor` populates `recordCtorTokens` for a record
// from a restored (cross-assembly) package (#1284).
test "restored record ctor token populated" {
  val packages: List[ProjectPackagePayload] = newList()
  packages.add(
    mkPkg(
      "RestoredCtor.Lib",
      "package RestoredCtor.Lib\n" + "\n" + "pub record Coord { x: Int y: Int }\n" + "\n" +
        "pub func makeCoord(a: in Int, b: in Int): Coord { Coord(x = a, y = b) }\n" +
        "\n" +
        "pub func sumCoord(c: in Coord): Int { c.x + c.y }\n"
    )
  )
  packages.add(
    mkPkg(
      "RestoredCtor.App",
      "package RestoredCtor.App\n" + "\n" + "import RestoredCtor.Lib\n" + "\n" + "func main(): Unit {\n" +
        "  val c = makeCoord(10, 32)\n" +
        "  println(sumCoord(c))\n" +
        "}\n"
    )
  )
  val result = compileAndRun("restored-ctor", packages, "RestoredCtor")
  assertEqualInt(result.exitCode, 0, "restored_record_ctor_token: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "42", "restored_record_ctor_token: sumCoord(Coord(10,32)) = 42")
}

// Regression for #1435: a shared package appearing as BOTH a bundle
// entry AND a stdlibSources entry must not cause double type-variable
// registration that corrupts `TyVar("")` resolution in subsequent
// packages.
test "stdlib self-build no duplicate type-var corruption" {
  val sharedSrc = "package Ix1435.Core\n" + "\n" + "pub generic[T] union Wrap {\n" + "  case Wrapped(value: T)\n" +
    "  case Empty\n" +
    "}\n" +
    "\n" +
    "pub func wrapInt(x: in Int): Wrap[Int] { Wrapped(value = x) }\n"
  val consumerSrc = "package Ix1435.App\n" + "\n" + "import Ix1435.Core\n" + "\n" +
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
  assertEqual(Str.trim(result.stdout), "8", "ix1435_no_duplicate_type_var_corruption: stdout=8")
}

// ─── Cfg-erasure diagnostics via the bridge ───────────────────────────────────
// F0012 fires for a malformed @cfg (literal argument instead of
// `feature = "X"`).  The bridge returns false.
test "cfg erasure F0012 malformed" {
  val pkgs: List[ProjectPackagePayload] = newList()
  pkgs.add(
    mkPkg(
      "CfgMalformed.App",
      "package CfgMalformed.App\n" + "\n" + "@cfg(\"experimental\")\n" + "pub func gated(): String { \"x\" }\n" + "\n" +
        "func main(): Unit { println(\"unreachable\") }\n"
    )
  )
  val empty: List[String] = newList()
  val ok = compileAndGetSucceeded("cfg-f0012", pkgs, "CfgF0012", empty, empty)
  assertTrue(not ok, "cfg_erasure_f0012_malformed: bridge should reject malformed @cfg")
}

// F0013 fires when a feature reference is absent from the manifest's
// declared set (typo guard).  F0013 is a WARNING — the build still
// succeeds.
test "cfg erasure F0013 typo warning does not fail build" {
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
