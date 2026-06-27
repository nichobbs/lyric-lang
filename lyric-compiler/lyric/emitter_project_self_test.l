//! emitter_project_self_test.l — end-to-end tests for the Phase 4 in-process
//! routing in `Lyric.Emitter.emitProject` (multi-package DOTNET builds).
//!
//! These tests build an `EmitProjectRequest`, hand it to `emitProject`, and
//! assert the produced DLL runs and prints the expected value.  Coverage:
//!   - Basic in-process routing (canInProc=true) for independent and
//!     cross-package bundles
//!   - Aliased cross-package import rewriting via `Lyric.AliasRewriter` (#1378)
//!   - Per-package symbol-table isolation — duplicate names and implicit-leak
//!     rejection (#1378, #1422, #1435)
//!   - @cfg feature erasure via `emitProject` (active / inactive / AND / file-level)
//!   - Restored-dep wiring crash-safety and subprocess-fallback routing
//!   - Stdlib import resolution from the in-process bridge
//!
//! Placed in `lyric-compiler/lyric/` (not `lyric-stdlib/tests/`) so it can
//! import `Lyric.Emitter` without overflowing the F# bootstrap emitter.
//! `lyric test` resolves the compiler-package imports from pre-compiled
//! stage-1 bundle DLLs via `Emitter.compilerClosureDllPaths`.
//!
//! Run in CI via:
//!   lyric test lyric-compiler/lyric/emitter_project_self_test.l
@test_module
package Lyric.EmitterProjectSelfTest

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
import Lyric.Emitter as Emitter

// ─── Helpers ────────────────────────────────────────────────────────────────
func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", Environment.getVarOrDefault("TEMP", Environment.getVarOrDefault("TMP", "/tmp")))
}

func freshTempDir(label: in String): String {
  val root = Path.join(tempBase(), "lyric-emitproj-" + label + "-" + uuidToString(newUuid()))
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

func mkProjectPkg(name: in String, source: in String): Emitter.ProjectPackage {
  val srcs: List[String] = newList()
  srcs.add(source)
  Emitter.ProjectPackage(name = name, sources = srcs)
}

func runEmitProjectOpts(
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
    packageVersion = "",
    depTemplateSrcs = newList(),
    nugetAssemblyPaths = newList()
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

func runEmitProject(
  label: in String, projectPkgs: in List[Emitter.ProjectPackage], assemblyName: in String
): Capture.CaptureResult {
  runEmitProjectOpts(label, projectPkgs, assemblyName, newList(), newList())
}

func runEmitProjectWithFeatures(
  label: in String,
  projectPkgs: in List[Emitter.ProjectPackage],
  assemblyName: in String,
  features: in List[String],
  declared: in List[String],
): Capture.CaptureResult {
  runEmitProjectOpts(label, projectPkgs, assemblyName, features, declared)
}

// ─── In-process routing: basic cases ─────────────────────────────────────────
// Two independent packages: pins the in-process routing path
// (canInProc=true) end-to-end.
test "emitProject in-process independent packages" {
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

// Cross-package call routed through the in-process bridge.
test "emitProject in-process cross-package call" {
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

// Aliased cross-package import: `import X as Y` + `Y.fn(...)` must
// resolve after `Lyric.AliasRewriter` rewrites the call to bare `fn(...)`.
// Regression for #1378.
test "emitProject aliased cross-package call" {
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

// Stdlib import resolved by the in-process bridge from LYRIC_STD_PATH /
// the runtime path, not from `stdlibSources` (#1202).
test "emitProject in-process stdlib import" {
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(
    mkProjectPkg(
      "StdlibImport.App",
      "package StdlibImport.App\n" + "\n" + "import Std.Core\n" + "\n" + "func greet(name: in String): String {\n" +
        "  \"hello \" + name\n" +
        "}\n" +
        "\n" +
        "func main(): Unit {\n" +
        "  val msg = greet(\"world\")\n" +
        "  println(msg)\n" +
        "}\n"
    )
  )
  val result = runEmitProject("emitproj-stdlib", pkgs, "StdlibImport")
  assertEqualInt(result.exitCode, 0, "in_process_stdlib_import: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "hello world", "in_process_stdlib_import: stdout matches expected")
}

// ─── Multi-file packages (#2575) ─────────────────────────────────────────────
// The issue's exact repro shape: a directory-form `[project.packages]` entry
// with TWO .l files, each carrying its own `package MDir` + `import` header,
// one file's `main` calling a function defined in the other.  The CLI's
// directory branch feeds each file as a separate source of one
// `ProjectPackage`; `emitProject` must merge them into a single valid
// compilation unit (file 2's raw `package` line mid-unit is a P0040 cascade).
// The fixture writes real files to a temp src dir and reads them back,
// mirroring `buildProject`'s directory branch.
test "emitProject multi-file directory package" {
  val fixtureDir = freshTempDir("mdir-2575")
  val srcDir = Path.join(fixtureDir, "src")
  match File.createDir(srcDir) {
    case Ok(_) -> ()
    case Err(e) -> panic("multi_file_dir_package: cannot create src dir: " + IOError.message(e))
  }
  val helperSrc = "package MDir\n" + "import Std.Core\n" + "\n" + "pub func helper(): Int { 42 }\n"
  val mainSrc = "package MDir\n" + "import Std.Core\n" + "\n" + "func main(): Unit {\n" + "  println(helper())\n" +
    "}\n"
  match File.writeText(Path.join(srcDir, "a_helper.l"), helperSrc) {
    case Ok(_) -> ()
    case Err(e) -> panic("multi_file_dir_package: cannot write helper: " + IOError.message(e))
  }
  match File.writeText(Path.join(srcDir, "b_main.l"), mainSrc) {
    case Ok(_) -> ()
    case Err(e) -> panic("multi_file_dir_package: cannot write main: " + IOError.message(e))
  }
  val sources: List[String] = newList()
  match File.readText(Path.join(srcDir, "a_helper.l")) {
    case Ok(s) -> sources.add(s)
    case Err(e) -> panic("multi_file_dir_package: cannot read helper: " + IOError.message(e))
  }
  match File.readText(Path.join(srcDir, "b_main.l")) {
    case Ok(s) -> sources.add(s)
    case Err(e) -> panic("multi_file_dir_package: cannot read main: " + IOError.message(e))
  }
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(Emitter.ProjectPackage(name = "MDir", sources = sources))
  val result = runEmitProject("mdir-2575-build", pkgs, "MDir")
  cleanup(fixtureDir)
  assertEqualInt(result.exitCode, 0, "multi_file_dir_package: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "42", "multi_file_dir_package: stdout matches expected")
}

// Multi-file merge edge cases: `//!` module-doc headers and file-level
// annotations must be stripped from every file (both are only valid before
// `package`, so one left mid-unit is a P0040), the first file's file-level
// annotation must be re-added to the merged header, and each file's `import`
// lines must union into the merged preamble so file 2's aliased import stays
// resolvable.  `shout` is never called at runtime — it pins the import union
// at typecheck (a dropped `import Std.String as Str` fails the build with
// T0020) without requiring `Lyric.Stdlib.String` beside the temp DLL.
test "emitProject multi-file package module docs and import union" {
  val fileOne = "//! first file module docs\n" + "@runtime_checked\n" + "package MDocs\n" + "import Std.Core\n" + "\n" +
    "pub func answer(): Int { 41 + 1 }\n"
  val fileTwo = "//! second file module docs\n" + "package MDocs\n" + "import Std.Core\n" + "import Std.String as Str\n" +
    "\n" +
    "pub func shout(s: in String): String { Str.trim(s) }\n" +
    "\n" +
    "func main(): Unit {\n" +
    "  println(answer())\n" +
    "}\n"
  val sources: List[String] = newList()
  sources.add(fileOne)
  sources.add(fileTwo)
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(Emitter.ProjectPackage(name = "MDocs", sources = sources))
  val result = runEmitProject("mdocs-2575", pkgs, "MDocs")
  assertEqualInt(result.exitCode, 0, "multi_file_module_docs: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "42", "multi_file_module_docs: stdout matches expected")
}

// ─── Per-package isolation ────────────────────────────────────────────────────
// Two unrelated packages each define a record named `Helper`.  Per-package
// symbol-table filtering must prevent a T0001 duplicate-name error (#1378).
test "per-package isolation duplicate name" {
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

// A package that does NOT import a sibling must fail typecheck when it
// references that sibling's types — NOT silently crash at codegen (#1422).
test "per-package isolation implicit leak rejected" {
  val tmpDir = freshTempDir("perpkg-leak")
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(mkProjectPkg("PerPkgLeak.Alpha", "package PerPkgLeak.Alpha\n" + "\n" + "pub record Helper { value: Int }\n"))
  pkgs.add(
    mkProjectPkg(
      "PerPkgLeak.Beta",
      "package PerPkgLeak.Beta\n" + "\n" + "func main(): Unit {\n" + "  val h = Helper(value = 1)\n" +
        "  println(h.value)\n" +
        "}\n"
    )
  )
  val dllPath = Path.join(tmpDir, "PerPkgLeak.dll")
  val req = Emitter.EmitProjectRequest(
    packages = pkgs,
    assemblyName = "PerPkgLeak",
    outputPath = dllPath,
    target = Emitter.Dotnet,
    restoredDllPaths = newList(),
    activeFeatures = newList(),
    declaredFeatures = newList(),
    packageVersion = "",
    depTemplateSrcs = newList(),
    nugetAssemblyPaths = newList()
  )
  val result = Emitter.emitProject(req)
  match result.outputPath {
    case None -> ()
    case Some(_) -> {
      cleanup(tmpDir)
      panic("per_package_isolation_implicit_leak: Beta should fail typecheck without import of Alpha")
    }
  }
  cleanup(tmpDir)
}

// ─── @cfg feature erasure via emitProject ────────────────────────────────────
// Feature INACTIVE: the gated function is erased; `main` falls back to
// the unconditional branch.
test "cfg erasure feature inactive" {
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

// Feature ACTIVE: the gated function is kept; `main` calls it.
test "cfg erasure feature active" {
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

// Multiple @cfg on the same item: item kept only when ALL predicates hold.
// `gated` requires both `alpha` and `beta`; activating only `alpha` erases it.
test "cfg erasure AND semantics" {
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

// File-level `@cfg` (above the `package` declaration) erases every item
// in the file when the feature is inactive.
test "cfg erasure file-level erases entire file" {
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

// ─── Restored-dep wiring ──────────────────────────────────────────────────────
// In-process loader reports DllMissing cleanly when handed a non-existent
// DLL path; `emitProject` surfaces it via `failResult` with no `outputPath`
// and a diagnostic that mentions the missing path (#1381).
test "restored dep wiring no crash" {
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
  restoredDlls.add("RestoredFallbackLib\t" + Path.join(tmpDir, "missing.dll"))
  val req = Emitter.EmitProjectRequest(
    packages = consumerPkgs,
    assemblyName = "RestoredFallbackApp",
    outputPath = consumerDll,
    target = Emitter.Dotnet,
    restoredDllPaths = restoredDlls,
    activeFeatures = newList(),
    declaredFeatures = newList(),
    packageVersion = "",
    depTemplateSrcs = newList(),
    nugetAssemblyPaths = newList()
  )
  val result = Emitter.emitProject(req)
  match result.outputPath {
    case None -> ()
    case Some(_) -> {
      cleanup(tmpDir)
      panic("restored_wiring: missing DLL must produce no output")
    }
  }
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

// A non-empty restoredDllPaths list forces canInProc=false (subprocess
// routing).  The missing dep causes a DllMissing diagnostic; outputPath
// must be None rather than silently succeeding (#1203).
test "emitProject subprocess fallback on restored dep" {
  val tmpDir = freshTempDir("emitproj-subprocess")
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(mkProjectPkg("ForcedSub.App", "package ForcedSub.App\n" + "\n" + "func main(): Unit { println(\"sub\") }\n"))
  val dllPath = Path.join(tmpDir, "ForcedSub.dll")
  val restoredDlls: List[String] = newList()
  restoredDlls.add("ForcedSub.Dep\t" + Path.join(tmpDir, "does-not-exist.dll"))
  val req = Emitter.EmitProjectRequest(
    packages = pkgs,
    assemblyName = "ForcedSub",
    outputPath = dllPath,
    target = Emitter.Dotnet,
    restoredDllPaths = restoredDlls,
    activeFeatures = newList(),
    declaredFeatures = newList(),
    packageVersion = "",
    depTemplateSrcs = newList(),
    nugetAssemblyPaths = newList()
  )
  val result = Emitter.emitProject(req)
  match result.outputPath {
    case None -> ()
    case Some(_) -> {
      cleanup(tmpDir)
      panic("forced_subprocess_fallback: expected no output when restored dep is missing")
    }
  }
  cleanup(tmpDir)
}

// ─── perPackageAssemblyName multi-segment coverage (#2653) ───────────────────
// Verifies that multi-segment Std.* and non-Std package names map to the
// expected assembly name on both targets, matching the F# emitter's convention.
test "perPackageAssemblyName single segment Std" {
  assertEqual(
    Emitter.perPackageAssemblyName("Std.Core", Emitter.Dotnet),
    "Lyric.Stdlib.Core",
    "perPackageAssemblyName: Std.Core -> Lyric.Stdlib.Core"
  )
}

test "perPackageAssemblyName multi-segment Std" {
  assertEqual(
    Emitter.perPackageAssemblyName("Std.Testing.Mocking", Emitter.Dotnet),
    "Lyric.Stdlib.TestingMocking",
    "perPackageAssemblyName: Std.Testing.Mocking -> Lyric.Stdlib.TestingMocking"
  )
}

test "perPackageAssemblyName multi-segment Std JVM" {
  assertEqual(
    Emitter.perPackageAssemblyName("Std.Testing.Mocking", Emitter.Jvm),
    "Lyric.Stdlib.TestingMocking.Jvm",
    "perPackageAssemblyName: Std.Testing.Mocking/Jvm -> Lyric.Stdlib.TestingMocking.Jvm"
  )
}

test "perPackageAssemblyName non-Std single segment" {
  assertEqual(
    Emitter.perPackageAssemblyName("Lyric", Emitter.Dotnet),
    "Lyric.Lyric",
    "perPackageAssemblyName: Lyric -> Lyric.Lyric"
  )
}

test "perPackageAssemblyName non-Std multi-segment" {
  assertEqual(
    Emitter.perPackageAssemblyName("Msil.Bridge", Emitter.Dotnet),
    "Lyric.Msil.Bridge",
    "perPackageAssemblyName: Msil.Bridge -> Lyric.Msil.Bridge"
  )
}
