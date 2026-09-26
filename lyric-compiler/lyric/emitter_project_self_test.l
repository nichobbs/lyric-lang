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
import Lyric.Parser as Parser
import Lyric.ImplDefaults as ImplDefaults

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
  val paths: List[String] = newList()
  paths.add("")
  Emitter.ProjectPackage(name = name, sources = srcs, paths = paths)
}

func mkProjectPkgMulti(name: in String, sources: in List[String]): Emitter.ProjectPackage {
  val paths: List[String] = newList()
  var i = 0
  while i < sources.count {
    paths.add("")
    i = i + 1
  }
  Emitter.ProjectPackage(name = name, sources = sources, paths = paths)
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
    nugetAssemblyPaths = newList(),
    defines = newList()
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

// JVM counterpart of `runEmitProjectOpts` (#3253): `emitProject` merges
// multi-file packages via `mergePackageSources` BEFORE dispatching on
// `req.target` (see `Lyric.Emitter.emitProject`), so the merge itself is
// target-agnostic — but only the `--target dotnet` path above was ever
// exercised by a runtime test. Routes through `emitProjectJvmInProcess`
// (`req.target = Emitter.Jvm`, `outputPath` ending in `.jar`) and runs the
// produced JAR with `java -jar` instead of `dotnet exec`.
func runEmitProjectJvmOpts(
  label: in String, projectPkgs: in List[Emitter.ProjectPackage], assemblyName: in String
): Capture.CaptureResult {
  val dir = freshTempDir(label)
  val jarPath = Path.join(dir, assemblyName + ".jar")
  val req = Emitter.EmitProjectRequest(
    packages = projectPkgs,
    assemblyName = assemblyName,
    outputPath = jarPath,
    target = Emitter.Jvm,
    restoredDllPaths = newList(),
    activeFeatures = newList(),
    declaredFeatures = newList(),
    packageVersion = "",
    depTemplateSrcs = newList(),
    nugetAssemblyPaths = newList(),
    defines = newList()
  )
  val result = Emitter.emitProject(req)
  match result.outputPath {
    case None -> {
      cleanup(dir)
      panic(label + ": emitProject (jvm) produced no output (diagnostics on stderr)")
    }
    case Some(_) -> ()
  }
  val args: List[String] = newList()
  args.add("-jar")
  args.add(jarPath)
  val captured = Capture.runCaptureWithDiagnostics("java", args, "")
  cleanup(dir)
  captured
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

// ─── Alias-qualified extern type in a function SIGNATURE (#6338) ────────────
// An `import X as Y` + `Y.ExternType` reference used as a function
// PARAMETER type: `Lyric.AliasRewriter` flattens it to the fully-qualified
// 3-segment path (`Helper.JList` here) at the AST level before codegen ever
// sees it. #6338's narrowed trigger (D-progress-769): the JVM auto-FFI
// signature resolver mis-fires ONLY when that alias-qualified extern type's
// SHORT NAME collides with a type declared locally in the CALLER's own
// package — the resolver preferred the local short name and built the
// caller's own package + that name as the FQN (`Caller.JList`) instead of
// resolving through the alias to the real extern (`java.util.ArrayList`),
// panicking with "class 'Caller.JList' not found". A same-shaped call
// (`H.JList.new()`) hits the identical bug in the auto-FFI call-site
// resolver. `describeExtern`'s body forces both the extern-typed PARAMETER
// (proves the signature resolved to the real `ArrayList`, not a bogus
// `Caller.JList` class) and the local record (proves the collision doesn't
// go the other way — the caller's own type stays intact for its own
// unqualified uses) to be exercised at runtime, not just compiled.
test "emitProject alias-qualified extern type signature collision (JVM)" {
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(
    mkProjectPkg(
      "Alias6338.Helper",
      "package Alias6338.Helper\n" + "\n" + "extern type JList = \"java.util.ArrayList\"\n"
    )
  )
  pkgs.add(
    mkProjectPkg(
      "Alias6338.App",
      "package Alias6338.App\n" + "\n" + "import Alias6338.Helper as H\n" + "\n" + "record JList {\n" +
        "  tag: String\n" +
        "}\n" +
        "\n" +
        "pub func describeExtern(x: H.JList): Int {\n" +
        "  x.size()\n" +
        "}\n" +
        "\n" +
        "func main(): Unit {\n" +
        "  val e = H.JList.new()\n" +
        "  e.add(\"a\")\n" +
        "  e.add(\"b\")\n" +
        "  e.add(\"c\")\n" +
        "  val local = JList(tag = \"local-value\")\n" +
        "  println(describeExtern(e))\n" +
        "  println(local.tag)\n" +
        "}\n"
    )
  )
  val result = runEmitProjectJvmOpts("alias-6338-jvm", pkgs, "Alias6338")
  assertEqualInt(
    result.exitCode,
    0,
    "alias_qualified_extern_signature_collision_jvm: exit 0 (stderr=" + result.stderr + ")"
  )
  assertEqual(
    Str.trim(result.stdout),
    "3\nlocal-value",
    "alias_qualified_extern_signature_collision_jvm: real ArrayList size + local record's own field both correct"
  )
}

// MSIL counterpart: same alias-qualified-extern-vs-local-collision shape,
// against a real CLR extern (`System.IO.StringWriter`). D-progress-769 found
// MSIL already resolves this correctly (`cctx.externTypeNames` is a
// project-global extern-only table, never biased by a same-package local
// type the way JVM's `ownAwareExternTypes` collision override is) — this
// pins that MSIL stays correct alongside the JVM fix above.
test "emitProject alias-qualified extern type signature collision (MSIL)" {
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(
    mkProjectPkg(
      "Alias6338Msil.Helper",
      "package Alias6338Msil.Helper\n" + "\n" + "extern type SW = \"System.IO.StringWriter\"\n"
    )
  )
  pkgs.add(
    mkProjectPkg(
      "Alias6338Msil.App",
      "package Alias6338Msil.App\n" + "\n" + "import Alias6338Msil.Helper as H\n" + "\n" + "record SW {\n" +
        "  tag: String\n" +
        "}\n" +
        "\n" +
        "pub func describeExtern(x: H.SW): String {\n" +
        "  x.Write(\"cross-pkg\")\n" +
        "  x.ToString()\n" +
        "}\n" +
        "\n" +
        "func main(): Unit {\n" +
        "  val e = H.SW.new()\n" +
        "  val local = SW(tag = \"local-value\")\n" +
        "  println(describeExtern(e))\n" +
        "  println(local.tag)\n" +
        "}\n"
    )
  )
  val result = runEmitProject("alias-6338-msil", pkgs, "Alias6338Msil")
  assertEqualInt(
    result.exitCode,
    0,
    "alias_qualified_extern_signature_collision_msil: exit 0 (stderr=" + result.stderr + ")"
  )
  assertEqual(
    Str.trim(result.stdout),
    "cross-pkg\nlocal-value",
    "alias_qualified_extern_signature_collision_msil: real StringWriter output + local record's own field both correct"
  )
}

// Control pin: the NON-colliding shape (no local `JList` in the caller) —
// D-progress-769 found this already resolves correctly even before the
// #6338 fix (`Lyric.AliasRewriter` flattens the alias correctly; the
// collision is what made the JVM auto-FFI resolver pick the wrong table
// entry). Pins that the fix above did not disturb the already-working path.
test "emitProject alias-qualified extern type signature non-collision control (JVM)" {
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(
    mkProjectPkg(
      "Alias6338NoCollide.Helper",
      "package Alias6338NoCollide.Helper\n" + "\n" + "extern type JList = \"java.util.ArrayList\"\n"
    )
  )
  pkgs.add(
    mkProjectPkg(
      "Alias6338NoCollide.App",
      "package Alias6338NoCollide.App\n" + "\n" + "import Alias6338NoCollide.Helper as H\n" + "\n" +
        "pub func describeExtern(x: H.JList): Int {\n" +
        "  x.size()\n" +
        "}\n" +
        "\n" +
        "func main(): Unit {\n" +
        "  val e = H.JList.new()\n" +
        "  e.add(\"a\")\n" +
        "  e.add(\"b\")\n" +
        "  println(describeExtern(e))\n" +
        "}\n"
    )
  )
  val result = runEmitProjectJvmOpts("alias-6338-nocollide-jvm", pkgs, "Alias6338NoCollide")
  assertEqualInt(
    result.exitCode,
    0,
    "alias_qualified_extern_signature_noncollision_control_jvm: exit 0 (stderr=" + result.stderr + ")"
  )
  assertEqual(
    Str.trim(result.stdout),
    "2",
    "alias_qualified_extern_signature_noncollision_control_jvm: real ArrayList size correct"
  )
}

// GENERIC-extern-type variant of the #6338 collision shape above: the
// alias-qualified reference `H.JDict[String, String]` parses to `TGenericApp`
// (`head: ModulePath, args: List[TypeArg]`), not the plain `TRef`/`TPath`
// `H.JList` parses to.  Pins that the #6338 fix's alias-qualified,
// collision-aware resolution also covers the `TGenericApp` type-expr shape,
// not just the non-generic one the three tests above exercise.  Construction
// goes through `@externTarget` for the zero-arg constructor only (generic
// constructor shorthand — `.new()` on a generic extern type — is docs/48
// Q48-001, deferred; a zero-arg ctor has no type-parameter-dependent
// descriptor, so a concretely-typed `newJDict(): JDict[String, String]`
// wrapper is safe); `.put`/`.size` go through ordinary auto-FFI method-call
// resolution (`d.put(...)`) instead of hand-written `@externTarget`
// wrappers — `@externTarget` requires an EXACT literal descriptor match,
// and `ConcurrentHashMap<K,V>.put` erases to `Object put(Object, Object)`
// in real JDK bytecode, so a concretely `String`-typed `@externTarget`
// wrapper resolves to a nonexistent `(String,String)String` overload
// (`NoSuchMethodError`) — exactly like the passing `JList`/`ArrayList`
// tests above already call `.add(...)` via auto-FFI, not a hand-written
// wrapper, for the identical erasure reason.  `describeExtern`'s parameter
// still forces the TGenericApp-typed signature to resolve to the real
// `ConcurrentHashMap`, not the caller's own colliding `JDict` record.
test "emitProject alias-qualified GENERIC extern type signature collision (JVM, TGenericApp)" {
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(
    mkProjectPkg(
      "Alias6338Generic.Helper",
      "package Alias6338Generic.Helper\n" + "\n" +
        "extern type JDict[K, V] = \"java.util.concurrent.ConcurrentHashMap\"\n" +
        "\n" +
        "@externTarget(\"java.util.concurrent.ConcurrentHashMap.<init>\")\n" +
        "func newJDict(): JDict[String, String] = ()\n" +
        "\n" +
        "pub func makeDict(): JDict[String, String] {\n" +
        "  val d = newJDict()\n" +
        "  d.put(\"a\", \"1\")\n" +
        "  d.put(\"b\", \"2\")\n" +
        "  d\n" +
        "}\n"
    )
  )
  pkgs.add(
    mkProjectPkg(
      "Alias6338Generic.App",
      "package Alias6338Generic.App\n" + "\n" + "import Alias6338Generic.Helper as H\n" + "\n" + "record JDict {\n" +
        "  tag: String\n" +
        "}\n" +
        "\n" +
        "pub func describeExtern(x: H.JDict[String, String]): Int {\n" +
        "  x.size()\n" +
        "}\n" +
        "\n" +
        "func main(): Unit {\n" +
        "  val e = H.makeDict()\n" +
        "  val local = JDict(tag = \"local-value\")\n" +
        "  println(describeExtern(e))\n" +
        "  println(local.tag)\n" +
        "}\n"
    )
  )
  val result = runEmitProjectJvmOpts("alias-6338-generic-jvm", pkgs, "Alias6338Generic")
  assertEqualInt(
    result.exitCode,
    0,
    "alias_qualified_generic_extern_signature_collision_jvm: exit 0 (stderr=" + result.stderr + ")"
  )
  assertEqual(
    Str.trim(result.stdout),
    "2\nlocal-value",
    "alias_qualified_generic_extern_signature_collision_jvm: real ConcurrentHashMap size + local record's own field both correct"
  )
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
  pkgs.add(mkProjectPkgMulti("MDir", sources))
  val result = runEmitProject("mdir-2575-build", pkgs, "MDir")
  cleanup(fixtureDir)
  assertEqualInt(result.exitCode, 0, "multi_file_dir_package: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "42", "multi_file_dir_package: stdout matches expected")
}

// JVM variant of the above (#3253): the identical two-file directory-package
// shape, but routed through `emitProjectJvmInProcess` and run under `java`
// instead of `dotnet exec`. Guards that a future change re-introducing the
// #2575 bug on the JVM-specific merge/dispatch path (rather than the
// dotnet-only path the test above exercises) is caught by CI too.
test "emitProject multi-file directory package (JVM)" {
  val fixtureDir = freshTempDir("mdir-2575-jvm")
  val srcDir = Path.join(fixtureDir, "src")
  match File.createDir(srcDir) {
    case Ok(_) -> ()
    case Err(e) -> panic("multi_file_dir_package_jvm: cannot create src dir: " + IOError.message(e))
  }
  val helperSrc = "package MDirJvm\n" + "import Std.Core\n" + "\n" + "pub func helper(): Int { 42 }\n"
  val mainSrc = "package MDirJvm\n" + "import Std.Core\n" + "\n" + "func main(): Unit {\n" + "  println(helper())\n" +
    "}\n"
  match File.writeText(Path.join(srcDir, "a_helper.l"), helperSrc) {
    case Ok(_) -> ()
    case Err(e) -> panic("multi_file_dir_package_jvm: cannot write helper: " + IOError.message(e))
  }
  match File.writeText(Path.join(srcDir, "b_main.l"), mainSrc) {
    case Ok(_) -> ()
    case Err(e) -> panic("multi_file_dir_package_jvm: cannot write main: " + IOError.message(e))
  }
  val sources: List[String] = newList()
  match File.readText(Path.join(srcDir, "a_helper.l")) {
    case Ok(s) -> sources.add(s)
    case Err(e) -> panic("multi_file_dir_package_jvm: cannot read helper: " + IOError.message(e))
  }
  match File.readText(Path.join(srcDir, "b_main.l")) {
    case Ok(s) -> sources.add(s)
    case Err(e) -> panic("multi_file_dir_package_jvm: cannot read main: " + IOError.message(e))
  }
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(mkProjectPkgMulti("MDirJvm", sources))
  val result = runEmitProjectJvmOpts("mdir-2575-jvm-build", pkgs, "MDirJvm")
  cleanup(fixtureDir)
  assertEqualInt(result.exitCode, 0, "multi_file_dir_package_jvm: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "42", "multi_file_dir_package_jvm: stdout matches expected")
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
  pkgs.add(mkProjectPkgMulti("MDocs", sources))
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
    nugetAssemblyPaths = newList(),
    defines = newList()
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

// Multi-source package + file-level `@cfg`: `mergePackageSources` only calls
// `fileIsCfgErasedByFeatures` on the `sources.count > 1` path (the
// `sources.count == 1` fast path returns the lone source verbatim), so a
// single-source erasure test never exercises this branch.  Both files
// declare a same-named function so an erasure regression (the gated file's
// body always merging in) is detectable as a compile failure, not merely as
// an unobserved dead function (#4527).
test "cfg erasure file-level with multiple sources in one package" {
  val pkgs: List[Emitter.ProjectPackage] = newList()
  val libSources: List[String] = newList()
  libSources.add("package CfgMultiSrc.Lib\n" + "\n" + "pub func pick(): Int { 1 }\n")
  libSources.add("@cfg(feature = \"extra\")\n" + "package CfgMultiSrc.Lib\n" + "\n" + "pub func pick(): Int { 999 }\n")
  pkgs.add(mkProjectPkgMulti("CfgMultiSrc.Lib", libSources))
  pkgs.add(
    mkProjectPkg(
      "CfgMultiSrc.App",
      "package CfgMultiSrc.App\n" + "\n" + "import CfgMultiSrc.Lib\n" + "\n" + "func main(): Unit {\n" +
        "  println(pick())\n" +
        "}\n"
    )
  )
  val empty: List[String] = newList()
  val declared: List[String] = newList()
  declared.add("extra")
  val result = runEmitProjectWithFeatures("cfg-multisrc-file-erase", pkgs, "CfgMultiSrcErase", empty, declared)
  assertEqualInt(result.exitCode, 0, "cfg_erasure_multisrc_file_level: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "1", "cfg_erasure_multisrc_file_level: stdout matches expected")
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
    nugetAssemblyPaths = newList(),
    defines = newList()
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
    nugetAssemblyPaths = newList(),
    defines = newList()
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

// ── #5512: cross-package impl of an imported interface ───────────────────────
// A consumer package implementing an interface declared in another in-bundle
// package, referenced UNQUALIFIED (`impl Clock for TestClock`, not
// `impl A.Clock for TestClock`). Before the fix, `implIfaceNameMsil`'s
// single-segment fallback always qualified under the CONSUMER's own package
// (`pkgName + "." + segs[0]`), so this built an FQN like
// `EmitProjImplXPkg.App.Clock` — which has no TypeDef/TypeRef row — and
// `lowerMImpl` panicked with "MPImpl interface type '<consumer
// pkg>.Clock' has no TypeDef or TypeRef row". `implIfaceNameMsil` now
// resolves the single-segment case via `resolveTypeFqn` (the same
// scope-tiered own-package/imported-package lookup every other
// cross-package type-name reference uses), which finds the DEFINING
// package's registered `Clock` interface instead.
test "emitProject cross-package impl of an imported interface (unqualified)" {
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(
    mkProjectPkg(
      "EmitProjImplXPkg.Lib",
      "package EmitProjImplXPkg.Lib\n" + "\n" + "pub interface Clock {\n" + "  func nowMillis(): Long\n" + "}\n"
    )
  )
  pkgs.add(
    mkProjectPkg(
      "EmitProjImplXPkg.App",
      "package EmitProjImplXPkg.App\n" + "\n" + "import EmitProjImplXPkg.Lib\n" + "\n" + "record TestClock {\n" +
        "  var millis: Long\n" +
        "}\n" +
        "\n" +
        "impl Clock for TestClock {\n" +
        "  func nowMillis(): Long {\n" +
        "    return self.millis\n" +
        "  }\n" +
        "}\n" +
        "\n" +
        "func main(): Unit {\n" +
        "  val c = TestClock(millis = 42i64)\n" +
        "  println(c.nowMillis().toString())\n" +
        "}\n"
    )
  )
  val result = runEmitProject("emitproj-implxpkg", pkgs, "EmitProjImplXPkg")
  assertEqualInt(
    result.exitCode,
    0,
    "emit_project_cross_package_impl_unqualified: exit 0 (stderr=" + result.stderr + ")"
  )
  assertEqual(Str.trim(result.stdout), "42", "emit_project_cross_package_impl_unqualified: stdout matches expected")
}

// Qualified form (`impl EmitProjImplXPkg.Lib.Clock for TestClock`) — already
// worked before the fix (the multi-segment branch returns the joined
// segments verbatim, which already matched the defining package's
// registered FQN); kept as a companion regression so both spellings stay
// covered.
test "emitProject cross-package impl of an imported interface (qualified)" {
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(
    mkProjectPkg(
      "EmitProjImplXPkgQ.Lib",
      "package EmitProjImplXPkgQ.Lib\n" + "\n" + "pub interface Clock {\n" + "  func nowMillis(): Long\n" + "}\n"
    )
  )
  pkgs.add(
    mkProjectPkg(
      "EmitProjImplXPkgQ.App",
      "package EmitProjImplXPkgQ.App\n" + "\n" + "import EmitProjImplXPkgQ.Lib\n" + "\n" + "record TestClock {\n" +
        "  var millis: Long\n" +
        "}\n" +
        "\n" +
        "impl EmitProjImplXPkgQ.Lib.Clock for TestClock {\n" +
        "  func nowMillis(): Long {\n" +
        "    return self.millis\n" +
        "  }\n" +
        "}\n" +
        "\n" +
        "func main(): Unit {\n" +
        "  val c = TestClock(millis = 7i64)\n" +
        "  println(c.nowMillis().toString())\n" +
        "}\n"
    )
  )
  val result = runEmitProject("emitproj-implxpkgq", pkgs, "EmitProjImplXPkgQ")
  assertEqualInt(result.exitCode, 0, "emit_project_cross_package_impl_qualified: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "7", "emit_project_cross_package_impl_qualified: stdout matches expected")
}

// #6422/#6428 review: the containment mechanism itself — `Lyric.Emitter`'s
// `try`/`catch` around its `JvmBridge` call sites (`jvmBridgePanicDiagnostic`)
// — must convert a JVM codegen-refusal `Bug` (here the `error[J007]`
// erased-receiver guard) into a normal `EmitResult` failure: NO exception
// escapes `emit`, `outputPath` is `None`, and a diagnostic is carried. This
// is what keeps `lyric test`'s per-file loop from aborting the whole process
// on one file's codegen refusal (#6357).  The bridge-side message/code
// contract is covered separately by `jvm_trycatch_bridge_self_test.l`, which
// calls `Jvm.Bridge` directly and asserts the THROW — the two tests pin the
// two halves of the design (bridge throws; emitter contains).
//
// This test's repro USED TO BE a checker-legal (#6417) non-receiver
// `Self`-typed impl param (`other: in Self`) whose field was read — #6426
// shipped real `checkcast` emission for that shape, so it stopped panicking
// and this repro was replaced (D-progress-755) with a match binding on a
// user-defined generic union's payload (a function PARAMETER typed
// `Box[Widget]`, matched directly). #5956 then taught `scrutineeGenericArgs`
// to recover a bare-parameter scrutinee's own `TGenericApp` annotation
// (`recordParamGenericArgs`, `jvm/codegen/03_match.l`), so that repro
// stopped panicking too — confirmed by reverting `recordParamGenericArgs`
// locally and observing this test fail exactly as CI did, then restoring it
// and observing the case-payload `w.n` read compile clean.
//
// Replaced again with a shape `scrutineeGenericArgs` still leaves erased:
// the SAME union payload, but reached through a RECORD FIELD read
// (`h.box`) rather than a bare parameter/local name. `scrutineeGenericArgs`
// only recognises `EParen`/`EAwait`/`EList`/`ECall`/a single-segment
// `EPath` as its top-level scrutinee shape (`jvm/codegen/03_match.l`); a
// bare `EMember` field read used directly as a match scrutinee falls
// through its final `case _ -> newList()` arm and stays boxed `Object`, so
// `w.n` inside the match arm still hits the J007 refusal (verified directly
// against `./bin/lyric build --target jvm` on this exact source).
//
// Replaced a THIRD time (#6957): `scrutineeGenericArgs` gained a top-level
// `EMember` arm (`fieldGenericArgsOf`) that resolves a plain field read's
// own declared generic instantiation — but only when the field's RECEIVER
// is itself a bare local/parameter/`self` (`receiverClassOf`'s only
// resolvable shapes). `h.box` is exactly that shape, so it stopped
// panicking too (confirmed: reverting #6957's `EMember` arm locally
// reproduces this test's failure with the two-level repro below unchanged
// to one level, restoring it passes). The repro now nests one level
// deeper — `h.wrap.box`, where the field's own receiver (`h.wrap`) is
// itself an `EMember`, not a bare `EPath` — so `receiverClassOf` returns
// `None` for it and `fieldGenericArgsOf` falls through to its safe
// `newList()` default, keeping `w.n` erased and the J007 refusal reachable
// (verified directly against `./bin/lyric build --target jvm` on this
// exact source).
test "emit(target = Jvm) contains a codegen-refusal Bug as an EmitResult failure, not a thrown exception (#6422)" {
  val dir = freshTempDir("jvm-contain-j007")
  val source = "package ContainJ007.App\n" + "\n" + "record Widget {\n" + "  n: Int\n" + "}\n" + "\n" +
    "union Box[T] {\n" +
    "  case Full(value: T)\n" +
    "  case Empty\n" +
    "}\n" +
    "\n" +
    "record Wrap {\n" +
    "  box: Box[Widget]\n" +
    "}\n" +
    "\n" +
    "record Holder {\n" +
    "  wrap: Wrap\n" +
    "}\n" +
    "\n" +
    "func unwrap(h: Holder): Int {\n" +
    "  match h.wrap.box {\n" +
    "    case Full(w) -> w.n\n" +
    "    case Empty -> 0\n" +
    "  }\n" +
    "}\n" +
    "\n" +
    "func main(): Unit {\n" +
    "  println(unwrap(Holder(wrap = Wrap(box = Full(value = Widget(n = 40))))))\n" +
    "}\n"
  val noDefines: List[String] = newList()
  val req = Emitter.EmitRequest(
    source = source,
    assemblyName = "ContainJ007",
    outputPath = Path.join(dir, "ContainJ007.jar"),
    target = Emitter.Jvm,
    packageVersion = "",
    defines = noDefines,
    path = ""
  )
  var threw = false
  val result = try {
    Emitter.emit(req)
  } catch Bug as b {
    threw = true
    Emitter.EmitResult(outputPath = None, diagnostics = newList())
  }
  match File.deleteDirRecursive(dir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }
  assertFalse(threw, "the codegen-refusal Bug must be contained inside emit, never thrown to the caller")
  match result.outputPath {
    case None -> assertTrue(true, "no output artifact on a contained failure")
    case Some(p) -> assertTrue(false, "emit must fail (got outputPath " + p + ")")
  }
  assertTrue(result.diagnostics.count > 0, "the contained failure carries a diagnostic for the CLI to render")
  // #6462: the contained refusal keeps its J-code in the structured result
  // (the emitter boundary passes `error[J0..]`-prefixed panics through
  // verbatim into `EmitResult.diagnostics`).
  var diagText = ""
  var cdi = 0
  while cdi < result.diagnostics.count {
    diagText = diagText + result.diagnostics[cdi].code + ": " + result.diagnostics[cdi].message + "\n"
    cdi = cdi + 1
  }
  assertTrue(
    Str.contains(diagText, "J007"),
    "the contained refusal carries its J007 code in EmitResult.diagnostics (got: " + diagText + ")"
  )
  // #6464: the diagnostic's span carries the REAL `line:col` the panic
  // message embeds (`ContainJ007.App:22:21` — the `w` receiver of `w.n` in
  // `case Full(w) -> w.n`), not the synthetic file-start point span every
  // contained panic used to get.
  var j007Idx = -1
  var sdi = 0
  while sdi < result.diagnostics.count {
    if result.diagnostics[sdi].code == "J007" {
      j007Idx = sdi
    }
    sdi = sdi + 1
  }
  assertTrue(j007Idx >= 0, "a J007 diagnostic is present in the result")
  if j007Idx >= 0 {
    val sp = result.diagnostics[j007Idx].span
    assertEqualInt(
      sp.startPos.line,
      22,
      "J007 span points at the real source line (got: " + toString(sp.startPos.line) + ")"
    )
    assertEqualInt(
      sp.startPos.column,
      21,
      "J007 span points at the real source column (got: " + toString(sp.startPos.column) + ")"
    )
  }
}

// #6464: direct unit coverage for `Emitter.parsePanicSpan` — the T0119
// message shape (`error[T0119] <line>:<col>: <text>`, no dotted-package
// prefix ahead of the location, unlike J007's `Pkg.File:line:col:`) has no
// end-to-end path into `EmitResult.diagnostics` in any existing suite (a
// typo'd extern static member is the only reachable T0119 site, and its
// dedicated end-to-end pin in `msil_project_bridge_self_test.l` asserts the
// raw `Msil.Bridge` panic message, one layer below where the emitter
// boundary builds the diagnostic's span) — so this pins the parser
// directly against both message shapes it has to handle, plus the
// no-location case (T0115) it must fall back cleanly on.
test "parsePanicSpan parses the T0119 `] line:col:` shape (#6464)" {
  val msg = "error[T0119] 4:11: extern member access 'System.Math.PIE' does not resolve"
  match Emitter.parsePanicSpan(msg) {
    case Some(sp) -> {
      assertEqualInt(sp.startPos.line, 4, "T0119-shape: line")
      assertEqualInt(sp.startPos.column, 11, "T0119-shape: column")
    }
    case None -> assertTrue(false, "parsePanicSpan should find a location in a T0119-shaped message")
  }
}

test "parsePanicSpan parses the J-code `]: Pkg.File:line:col:` shape (#6464)" {
  val msg = "error[J007]: ContainJ007.App:14:21: member 'n' cannot be resolved on an erased receiver"
  match Emitter.parsePanicSpan(msg) {
    case Some(sp) -> {
      assertEqualInt(sp.startPos.line, 14, "J-code-shape: line")
      assertEqualInt(sp.startPos.column, 21, "J-code-shape: column")
    }
    case None -> assertTrue(false, "parsePanicSpan should find a location in a J-code-shaped message")
  }
}

test "parsePanicSpan returns None for a message with no embedded location (#6464)" {
  val msg = "error[T0115]: cannot resolve qualified reference 'Foo.bar' — it does not name a value, function, type, or member this compilation can verify."
  match Emitter.parsePanicSpan(msg) {
    case Some(sp) -> assertTrue(
      false,
      "T0115 carries no location; parsePanicSpan must return None, not a spurious match (got line " +
        toString(sp.startPos.line) +
        ")"
    )
    case None -> assertTrue(true, "no location found, as expected")
  }
}

// #6521 review (#6522): direct unit coverage for the MSIL erased-receiver
// backstop's `error[T0121] <line>:<col>:` message shape — the T0119-family
// format `codegen.l`'s EMember exhausted tail now self-tags with (see that
// panic's own comment).  No end-to-end path into `EmitResult.diagnostics`
// exists in this suite for the SAME reason `msil_project_bridge_self_test.l`
// records for its analogous MPImpl-dedup test: five independently-motivated
// candidate erasure shapes (same-package match-arm binding, cross-assembly
// restored generic-union payload, in-bundle cross-package generic-union
// payload, `Result[Widget, _]?` unwrap, and a boxed-ABI lambda-callback
// parameter) were tried and every one resolves the receiver's real type
// through an existing, more specific codegen path — MSIL's in-bundle
// generics reification (docs/43) and #1939's lambda-param unboxing both
// track concrete instantiations end-to-end where the JVM backend's older
// erased-to-Object path (J007's own trigger, `scrutineeGenericArgs`) does
// not.  Even the one historically-real hit, `examples/docker_client.l`'s
// `e.statusCode`, no longer reaches the tail post-#6503/#6520 (verified:
// ilverifies clean).  This pins the SHAPE the message must keep producing —
// digit-scan span recovery working for this exact code — so a future
// message-format regression fails loudly here rather than silently losing
// span precision the next time (if ever) a real trigger surfaces.
test "parsePanicSpan parses the T0121 erased-receiver `] line:col:` shape (#6521/#6522)" {
  val msg = "error[T0121] 7:10: member 'statusCode' (in Pkg.func) could not be resolved on its receiver"
  match Emitter.parsePanicSpan(msg) {
    case Some(sp) -> {
      assertEqualInt(sp.startPos.line, 7, "T0121-shape: line")
      assertEqualInt(sp.startPos.column, 10, "T0121-shape: column")
    }
    case None -> assertTrue(false, "parsePanicSpan should find a location in a T0121-shaped message")
  }
}

// #6447 (#6446 review): an UNRESOLVED diamond — two same-file interfaces
// each defaulting the same name onto one target, no override anywhere —
// must be rejected at compile time under T0117 (docs/01 §2.12: "diamond
// conflicts are resolved by requiring explicit override"), never reach the
// backends as two same-named synthesized members (a duplicate-member
// backend crash pre-#6447).  Asserted through `Emitter.emit` so the
// rejection flows as a normal `EmitResult` failure, not a thrown exception.
test "unresolved diamond default conflict is rejected with T0117, not a backend crash (#6447)" {
  val dir = freshTempDir("diamond-t0117")
  val source = "package DiamondT0117\n" + "\n" + "record Thing {\n" + "  base: Int\n" + "}\n" + "\n" +
    "interface Alpha {\n" +
    "  func label(self: in Self): Int {\n" +
    "    1\n" +
    "  }\n" +
    "}\n" +
    "\n" +
    "interface Beta {\n" +
    "  func label(self: in Self): Int {\n" +
    "    2\n" +
    "  }\n" +
    "}\n" +
    "\n" +
    "impl Alpha for Thing {\n" +
    "}\n" +
    "\n" +
    "impl Beta for Thing {\n" +
    "}\n" +
    "\n" +
    "func main(): Unit {\n" +
    "  println(Thing(base = 0).label())\n" +
    "}\n"
  val noDefines: List[String] = newList()
  val req = Emitter.EmitRequest(
    source = source,
    assemblyName = "DiamondT0117",
    outputPath = Path.join(dir, "DiamondT0117.dll"),
    target = Emitter.Dotnet,
    packageVersion = "",
    defines = noDefines,
    path = ""
  )
  var threw = false
  val result = try {
    Emitter.emit(req)
  } catch Bug as b {
    threw = true
    Emitter.EmitResult(outputPath = None, diagnostics = newList())
  }
  match File.deleteDirRecursive(dir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }
  assertFalse(threw, "the diamond rejection must flow as a diagnostic, never a thrown exception")
  match result.outputPath {
    case None -> assertTrue(true, "no artifact for a rejected diamond")
    case Some(p) -> assertTrue(false, "emit must fail under T0117 (got outputPath " + p + ")")
  }
}

// #6445 rider (PR #6446 review disposition): the JVM counterpart of the
// dotnet diamond-conflict case above. `Lyric.ImplDefaults`'s diamond check
// runs in the target-independent middle end (`Lyric.Pipeline.pipeExpandAndRewrite`,
// before either backend bridge), so the same unresolved diamond must be
// rejected identically under `--target jvm`.
test "unresolved diamond default conflict is rejected with T0117 on JVM too (#6445)" {
  val dir = freshTempDir("diamond-t0117-jvm")
  val source = "package DiamondT0117Jvm\n" + "\n" + "record Thing {\n" + "  base: Int\n" + "}\n" + "\n" +
    "interface Alpha {\n" +
    "  func label(self: in Self): Int {\n" +
    "    1\n" +
    "  }\n" +
    "}\n" +
    "\n" +
    "interface Beta {\n" +
    "  func label(self: in Self): Int {\n" +
    "    2\n" +
    "  }\n" +
    "}\n" +
    "\n" +
    "impl Alpha for Thing {\n" +
    "}\n" +
    "\n" +
    "impl Beta for Thing {\n" +
    "}\n" +
    "\n" +
    "func main(): Unit {\n" +
    "  println(Thing(base = 0).label())\n" +
    "}\n"
  val noDefines: List[String] = newList()
  val req = Emitter.EmitRequest(
    source = source,
    assemblyName = "DiamondT0117Jvm",
    outputPath = Path.join(dir, "DiamondT0117Jvm.jar"),
    target = Emitter.Jvm,
    packageVersion = "",
    defines = noDefines,
    path = ""
  )
  var threw = false
  val result = try {
    Emitter.emit(req)
  } catch Bug as b {
    threw = true
    Emitter.EmitResult(outputPath = None, diagnostics = newList())
  }
  match File.deleteDirRecursive(dir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }
  assertFalse(threw, "the diamond rejection must flow as a diagnostic, never a thrown exception (JVM)")
  match result.outputPath {
    case None -> assertTrue(true, "no artifact for a rejected diamond (JVM)")
    case Some(p) -> assertTrue(false, "emit must fail under T0117 on JVM (got outputPath " + p + ")")
  }
}

// #6445 rider (PR #6446 review): a THREE-interface diamond conflict is still
// rejected exactly once (the per-target/name dedupe is unchanged), but the
// message now folds every supplier beyond the first two into "and N more"
// instead of silently dropping the third (and beyond). `Lyric.Pipeline`
// only ever PRINTS `Lyric.ImplDefaults`'s diagnostics to stderr via `gate`
// (`DiagnosticUtil.diagReportAndAbort`) before returning `None` — they never
// flow back through `Emitter.emit`'s `EmitResult.diagnostics` — so the
// message text is pinned by calling `ImplDefaults.inheritDefaultsFile`
// directly on the parsed source, the same way `typechecker_self_test.l`
// pins checker diagnostics via `parseCheck`.
test "three-interface diamond conflict folds the extra supplier into 'and N more' (#6445)" {
  val source = "package DiamondT0117Triple\n" + "\n" + "record Thing {\n" + "  base: Int\n" + "}\n" + "\n" +
    "interface Alpha {\n" +
    "  func label(self: in Self): Int {\n" +
    "    1\n" +
    "  }\n" +
    "}\n" +
    "\n" +
    "interface Beta {\n" +
    "  func label(self: in Self): Int {\n" +
    "    2\n" +
    "  }\n" +
    "}\n" +
    "\n" +
    "interface Gamma {\n" +
    "  func label(self: in Self): Int {\n" +
    "    3\n" +
    "  }\n" +
    "}\n" +
    "\n" +
    "impl Alpha for Thing {\n" +
    "}\n" +
    "\n" +
    "impl Beta for Thing {\n" +
    "}\n" +
    "\n" +
    "impl Gamma for Thing {\n" +
    "}\n" +
    "\n" +
    "func main(): Unit {\n" +
    "  println(Thing(base = 0).label())\n" +
    "}\n"
  val pr = Parser.parse(source)
  assertEqualInt(pr.diagnostics.count, 0, "3-way diamond fixture parses cleanly")
  val idRes = ImplDefaults.inheritDefaultsFile(pr.file)
  var foundExtra = false
  var t0117Count = 0
  var di = 0
  while di < idRes.diagnostics.count {
    if idRes.diagnostics[di].code == "T0117" {
      t0117Count = t0117Count + 1
      if Str.contains(idRes.diagnostics[di].message, "and 1 more") {
        foundExtra = true
      }
    }
    di = di + 1
  }
  assertTrue(foundExtra, "T0117 message folds the third supplier into 'and 1 more'")
  assertEqualInt(t0117Count, 1, "still exactly one T0117 diagnostic for the 3-way conflict (dedupe unchanged)")
}

// ─── depTemplateSrcs -> weaver template resolution (#3650) ──────────────────
// PR #3633 added the `depTemplatePkgs` loop in `Msil.Bridge`'s
// `compileProjectToMsilWithRestoredAndVersion` (parse each dep-template
// source, `Weaver.collectAspectTemplates`, resolve `from`-instances against
// them), threaded here from `Emitter.EmitProjectRequest.depTemplateSrcs`.
// Every existing self-test — including every OTHER test in this file —
// passes `depTemplateSrcs = newList()`, so that loop never actually ran in
// CI; `weaver_self_test.l` covers template collection/resolution at the
// in-process weaver level only, never through this bridge entry point.  This
// is the first test to exercise it with a non-empty `depTemplateSrcs`: a
// template aspect declared in a SEPARATE dep-package source (never part of
// `packages`, only `depTemplateSrcs` — the whole point of the dep-template
// mechanism is that the template's OWN package need not be compiled into the
// bundle), a `from`-instance in the main package, and the woven output
// actually compiled, run, and asserted on its runtime value (not just "no
// A0045").
func mkTemplatePkg(name: in String, source: in String): Emitter.ProjectPackage {
  mkProjectPkg(name, source)
}

test "emitProject depTemplateSrcs: from-instance aspect resolved against a dep-package template, woven output runs" {
  val templateSrc = "package DepTplLib.Logging\n" + "\n" + "pub aspect DoubleResult {\n" +
    "  matches: name like \"*\"\n" +
    "  around(args) -> ret {\n" +
    "    ret = proceed(args)\n" +
    "    ret = ret * 2\n" +
    "  }\n" +
    "}\n"
  val depTemplates: List[Emitter.ProjectPackage] = newList()
  depTemplates.add(mkTemplatePkg("DepTplLib.Logging", templateSrc))

  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(
    mkProjectPkg(
      "DepTplApp",
      "package DepTplApp\n" + "\n" + "aspect MyDouble from DepTplLib.Logging.DoubleResult {\n" +
        "  matches: name like \"compute\"\n" +
        "}\n" +
        "\n" +
        "pub func compute(x: in Int): Int { x + 1 }\n" +
        "\n" +
        "func main(): Unit {\n" +
        "  println(compute(5))\n" +
        "}\n"
    )
  )

  val dir = freshTempDir("emitproj-deptpl")
  val dllPath = Path.join(dir, "DepTplApp.dll")
  val req = Emitter.EmitProjectRequest(
    packages = pkgs,
    assemblyName = "DepTplApp",
    outputPath = dllPath,
    target = Emitter.Dotnet,
    restoredDllPaths = newList(),
    activeFeatures = newList(),
    declaredFeatures = newList(),
    packageVersion = "",
    depTemplateSrcs = depTemplates,
    nugetAssemblyPaths = newList(),
    defines = newList()
  )
  val result = Emitter.emitProject(req)

  var a0045Count = 0
  var di2 = 0
  while di2 < result.diagnostics.count {
    if result.diagnostics[di2].code == "A0045" {
      a0045Count = a0045Count + 1
    }
    di2 = di2 + 1
  }
  assertEqualInt(a0045Count, 0, "depTemplateSrcs: from-instance template resolves, no A0045 (unresolved template)")

  match result.outputPath {
    case None -> {
      cleanup(dir)
      panic("emitproj-deptpl: emitProject produced no output (diagnostics on stderr)")
    }
    case Some(_) -> ()
  }
  writeRuntimeConfig(dllPath)
  val args: List[String] = newList()
  args.add("exec")
  args.add(dllPath)
  val captured = Capture.runCaptureWithDiagnostics("dotnet", args, "")
  cleanup(dir)
  assertEqualInt(captured.exitCode, 0, "emitproj-deptpl: exit 0 (stderr=" + captured.stderr + ")")
  // compute(5) = 6, doubled by the dep-template's around advice = 12 --
  // proves the woven output isn't just "compiles", it actually RUNS the
  // template's advice body against the main package's matched function.
  assertEqual(Str.trim(captured.stdout), "12", "emitproj-deptpl: DoubleResult advice actually ran (5+1)*2=12")
}

// ─── #6628: compilerClosureDllPaths must verify bundle completeness ────────
//
// `Emitter.compilerClosureDllPaths` links a `@test_module`'s `Lyric.*`
// compiler-package imports against a pre-staged self-hosted compiler bundle
// (`<libDir>/selfhosted/Lyric.Compiler.dll`) when one exists. Before #6628's
// fix, the function trusted the bundle's mere EXISTENCE — a bundle staged
// before a package was added to a test's import closure (or before that
// package existed at all) would silently be used anyway, producing wrong
// runtime results instead of a build failure. These tests build a REAL
// bundle via `Emitter.emitCompilerBundle` (the same emit path
// `scripts/stage-selfhosted-compiler.sh` uses) covering exactly one small
// leaf compiler package's closure, then probe `compilerClosureDllPaths`
// against test sources that need a package the bundle does/doesn't cover.
test "compilerClosureDllPaths: stale bundle missing an imported package is reported, not silently trusted (#6628)" {
  val dir = freshTempDir("compilerclosure-stale")
  val shDir = Path.join(dir, "selfhosted")
  match File.createDir(shDir) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create " + shDir + ": " + IOError.message(e))
  }
  val bundlePath = Path.join(shDir, "Lyric.Compiler.dll")
  // Bundle covers ONLY Lyric.CliShell's closure (a real, tiny, leaf
  // compiler package: imports just Std.Core/Std.Collections/
  // Std.Environment/Std.String, no other Lyric.* packages).
  val bundleEntry = "package __bundle_entry__\nimport Lyric.CliShell\n"
  val bundleResult = Emitter.emitCompilerBundle(bundleEntry, bundlePath, Emitter.Dotnet)
  match bundleResult.outputPath {
    case None -> {
      cleanup(dir)
      panic("compilerclosure-stale: failed to build the test bundle fixture (diagnostics on stderr)")
    }
    case Some(_) -> ()
  }

  // A test source that imports a DIFFERENT real compiler package (also a
  // leaf w.r.t. Lyric.CliShell — Lyric.BuildDefines pulls in Lyric.Lexer/
  // Lyric.Parser, none of which is Lyric.CliShell) the bundle above does
  // NOT cover.
  val testSrc = "package Consumer\nimport Lyric.BuildDefines\n"
  val result = Emitter.compilerClosureDllPaths(testSrc, dir)
  cleanup(dir)

  assertTrue(
    result.missingPackages.count > 0,
    "stale bundle: missingPackages must be non-empty when the bundle doesn't cover the test's closure"
  )
  assertTrue(
    listContains(result.missingPackages, "Lyric.BuildDefines"),
    "stale bundle: missingPackages must name the actually-missing package 'Lyric.BuildDefines'"
  )
  assertTrue(
    not listContains(result.dlls, "Lyric.Compiler\t" + bundlePath),
    "stale bundle: an incomplete bundle must not be linked as if it were complete"
  )
}

test "compilerClosureDllPaths: a bundle that covers the whole closure is used, no missing packages (#6628 control)" {
  val dir = freshTempDir("compilerclosure-complete")
  val shDir = Path.join(dir, "selfhosted")
  match File.createDir(shDir) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create " + shDir + ": " + IOError.message(e))
  }
  val bundlePath = Path.join(shDir, "Lyric.Compiler.dll")
  // Bundle and test source both need exactly Lyric.CliShell's closure.
  val bundleEntry = "package __bundle_entry__\nimport Lyric.CliShell\n"
  val bundleResult = Emitter.emitCompilerBundle(bundleEntry, bundlePath, Emitter.Dotnet)
  match bundleResult.outputPath {
    case None -> {
      cleanup(dir)
      panic("compilerclosure-complete: failed to build the test bundle fixture (diagnostics on stderr)")
    }
    case Some(_) -> ()
  }

  val testSrc = "package Consumer\nimport Lyric.CliShell\n"
  val result = Emitter.compilerClosureDllPaths(testSrc, dir)
  cleanup(dir)

  assertEqualInt(result.missingPackages.count, 0, "complete bundle: no missing packages")
  assertEqualInt(result.dlls.count, 1, "complete bundle: exactly one restored-dep entry (the whole bundle)")
  assertEqual(
    result.dlls[0],
    "Lyric.Compiler\t" + bundlePath,
    "complete bundle: the single entry points at the bundle DLL"
  )
}

// Merging a multi-file package strips only each file's header `package` /
// `import` / `//!` lines; item bodies are carried over verbatim, so a body
// line that merely starts with `import ` (here inside a multi-line string)
// survives, and every merged body line still maps back to its file and line.
test "multi-file merge strips header lines only and keeps line origins" {
  val srcA = "//! doc\n@runtime_checked\npackage P\nimport Std.Core\n\n// note\nfunc a(): String {\n  \"\"\"\nimport not.a.decl\n\"\"\"\n}\n"
  val srcB = "package P\nimport Std.Core\nimport Std.String as Str\nfunc b(): Int { 1 }\n"
  val sources: List[String] = newList()
  sources.add(srcA)
  sources.add(srcB)
  val paths: List[String] = newList()
  paths.add("a.l")
  paths.add("b.l")
  val none: List[String] = newList()
  val merged = Emitter.mergePackageSourcesWithOrigins("P", sources, paths, none, none)
  val lines = Str.split(merged.source, "\n")
  var coreImports = 0
  var aliasImports = 0
  var bodyImportLine = -1
  var funcBLine = -1
  var docLines = 0
  var li = 0
  while li < lines.length {
    val line = lines[li]
    if line == "import Std.Core" {
      coreImports = coreImports + 1
    }
    if line == "import Std.String as Str" {
      aliasImports = aliasImports + 1
    }
    if line == "import not.a.decl" {
      bodyImportLine = li
    }
    if line == "func b(): Int { 1 }" {
      funcBLine = li
    }
    if Str.startsWith(line, "//!") {
      docLines = docLines + 1
    }
    li = li + 1
  }
  assertEqualInt(coreImports, 1, "duplicate header imports collapse into one")
  assertEqualInt(aliasImports, 1, "the aliased import is kept")
  assertEqualInt(docLines, 0, "module-doc lines are dropped")
  assertTrue(bodyImportLine >= 0, "an import-like line inside a body string is kept verbatim")
  assertTrue(funcBLine >= 0, "the second file's body is present")
  assertEqualInt(merged.origins.count, lines.length, "one origin per merged line")
  assertEqual(merged.origins[bodyImportLine].path, "a.l", "string line origin file")
  assertEqualInt(merged.origins[bodyImportLine].originalLine, 9, "string line origin line")
  assertEqual(merged.origins[funcBLine].path, "b.l", "second body origin file")
  assertEqualInt(merged.origins[funcBLine].originalLine, 4, "second body origin line")
}

// Imported generics end to end, on both targets (D-progress-946/947/948/949):
// a qualified call through an `as` alias, a return-only type parameter
// inferred from a `List` element type, `.copy` inside an imported generic
// body and on an imported record, and a specialised body calling its own
// package's import (`twice`), which the consumer does not import.
func importedGenericsPkgs(): List[Emitter.ProjectPackage] {
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(
    mkProjectPkg(
      "EPGen.Util",
      "package EPGen.Util\n" + "\n" + "pub func twice(n: in Int): Int {\n" + "  return n * 2\n" + "}\n"
    )
  )
  pkgs.add(
    mkProjectPkg(
      "EPGen.Core",
      "package EPGen.Core\n" + "\n" + "import EPGen.Util.{twice}\n" + "\n" + "pub union Node[M] {\n" +
        "  case Leaf(label: String)\n" +
        "  case Act(label: String, msg: M)\n" +
        "}\n" +
        "\n" +
        "pub record Box[M] {\n" +
        "  items: List[Node[M]]\n" +
        "  count: Int\n" +
        "}\n" +
        "\n" +
        "pub func leaf[M](label: in String): Node[M] {\n" +
        "  return Leaf(label = label)\n" +
        "}\n" +
        "\n" +
        "pub func labelOf[M](n: in Node[M]): String {\n" +
        "  return match n {\n" +
        "    case Leaf(l) -> l\n" +
        "    case Act(l, _) -> l\n" +
        "  }\n" +
        "}\n" +
        "\n" +
        "pub func boxOf[M](xs: in List[Node[M]]): Box[M] {\n" +
        "  return Box(items = xs, count = xs.count)\n" +
        "}\n" +
        "\n" +
        "pub func recount[M](b: in Box[M], n: in Int): Box[M] {\n" +
        "  return b.copy(count = n)\n" +
        "}\n" +
        "\n" +
        "pub func doubled[M](b: in Box[M]): Int {\n" +
        "  return twice(b.count)\n" +
        "}\n"
    )
  )
  pkgs.add(
    mkProjectPkg(
      "EPGen.App",
      "package EPGen.App\n" + "\n" + "import EPGen.Core as C\n" + "\n" + "union Msg {\n" + "  case Go\n" + "}\n" + "\n" +
        "func main(): Unit {\n" +
        "  val xs: List[C.Node[Msg]] = newList()\n" +
        "  xs.add(C.leaf(\"a\"))\n" +
        "  val b: C.Box[Msg] = C.boxOf(xs)\n" +
        "  val r: C.Box[Msg] = C.recount(b, 5)\n" +
        "  val c: C.Box[Msg] = b.copy(count = 7)\n" +
        "  println(C.labelOf(xs[0]) + \" \" + b.count.toString() + \" \" + r.count.toString() + \" \" + c.count.toString() + \" \" + C.doubled(b).toString())\n" +
        "}\n"
    )
  )
  pkgs
}

test "emitProject imported generics: qualified calls, expected types, record copy (MSIL)" {
  val result = runEmitProject("emitproj-impgen", importedGenericsPkgs(), "EPGen")
  assertEqualInt(result.exitCode, 0, "imported generics MSIL: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "a 1 5 7 2", "imported generics MSIL: output")
}

test "emitProject imported generics: qualified calls, expected types, record copy (JVM)" {
  val result = runEmitProjectJvmOpts("emitproj-impgen-jvm", importedGenericsPkgs(), "EPGen")
  assertEqualInt(result.exitCode, 0, "imported generics JVM: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "a 1 5 7 2", "imported generics JVM: output")
}

// A field read directly on an imported generic's call result, with the
// consuming package listed FIRST (the order `lyric test` bundles a test
// package in, #2885), on both targets (D-progress-950). The consumer's
// specialised copies used to be tokenised before the library's generic
// records were registered, so the call result erased to `object`: `.n`
// failed (T0121/J007), `.count` read the record as a collection, and an
// unannotated local resolved `n` by bare name against the unrelated
// same-named `LocalPair.n`.
func genericResultPkgs(): List[Emitter.ProjectPackage] {
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(
    mkProjectPkg(
      "EPRes.App",
      "package EPRes.App\n" + "\n" + "import EPRes.Lib.{tally, pairOf}\n" + "\n" + "record LocalPair[T] {\n" +
        "  first: T\n" +
        "  n: Int\n" +
        "}\n" +
        "\n" +
        "func main(): Unit {\n" +
        "  val xs: List[String] = newList()\n" +
        "  xs.add(\"a\")\n" +
        "  xs.add(\"b\")\n" +
        "  val p = pairOf(\"x\")\n" +
        "  val local = LocalPair(first = \"y\", n = 9)\n" +
        "  println(tally(xs).count.toString() + \" \" + pairOf(1).n.toString() + \" \" + p.n.toString() + \" \" + local.n.toString())\n" +
        "}\n"
    )
  )
  pkgs.add(
    mkProjectPkg(
      "EPRes.Lib",
      "package EPRes.Lib\n" + "\n" + "pub record Tally[T] {\n" + "  items: List[T]\n" + "  count: Int\n" + "}\n" + "\n" +
        "pub record Pair[T] {\n" +
        "  first: T\n" +
        "  n: Int\n" +
        "}\n" +
        "\n" +
        "pub func tally[T](xs: in List[T]): Tally[T] {\n" +
        "  return Tally(items = xs, count = xs.count)\n" +
        "}\n" +
        "\n" +
        "pub func pairOf[T](v: in T): Pair[T] {\n" +
        "  return Pair(first = v, n = 3)\n" +
        "}\n"
    )
  )
  pkgs
}

test "emitProject member read on an imported generic call result, consumer first (MSIL)" {
  val result = runEmitProject("emitproj-genres", genericResultPkgs(), "EPRes")
  assertEqualInt(result.exitCode, 0, "generic result MSIL: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "2 3 3 9", "generic result MSIL: output")
}

test "emitProject member read on an imported generic call result, consumer first (JVM)" {
  val result = runEmitProjectJvmOpts("emitproj-genres-jvm", genericResultPkgs(), "EPRes")
  assertEqualInt(result.exitCode, 0, "generic result JVM: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "2 3 3 9", "generic result JVM: output")
}

// A match on a generic union returned through a function, inside an
// imported generic specialised into the consumer, with the consumer listed
// first: once through a generic record's function-typed field, once through a
// function passed by name. The record's field type depends on the
// record's own type parameters, so MSIL must not register it as a closed
// instantiation (it named `Msg` as a class of the record's package and the
// match emitted an isinst against a nonexistent non-generic case class,
// T0120), and `Lyric.Mono` must bind `Msg` from the function reference
// instead of defaulting it to `Object` (an invalid cast at run time).
func genericFieldFnPkgs(): List[Emitter.ProjectPackage] {
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(
    mkProjectPkg(
      "EPFx.App",
      "package EPFx.App\n" + "\n" +
        "import EPFx.Core.{Effect, Go, Stay, Found, Hit, Miss, Program, describe, describeFn}\n" +
        "\n" +
        "union Msg {\n" +
        "  case Ok\n" +
        "}\n" +
        "\n" +
        "union Ev {\n" +
        "  case Ui(fx: Effect[Msg])\n" +
        "  case Save\n" +
        "}\n" +
        "\n" +
        "func toFx(e: in Ev): Found[Effect[Msg]] {\n" +
        "  return match e {\n" +
        "    case Ui(fx) -> Hit(v = fx)\n" +
        "    case Save -> Miss\n" +
        "  }\n" +
        "}\n" +
        "\n" +
        "func main(): Unit {\n" +
        "  val xs: List[Ev] = newList()\n" +
        "  xs.add(Ui(fx = Go(url = \"/a\")))\n" +
        "  xs.add(Save)\n" +
        "  xs.add(Ui(fx = Stay))\n" +
        "  val p: Program[Ev, Msg] = Program(classify = toFx)\n" +
        "  println(describe(p, xs) + \" \" + describeFn(toFx, xs))\n" +
        "}\n"
    )
  )
  pkgs.add(
    mkProjectPkg(
      "EPFx.Core",
      "package EPFx.Core\n" + "\n" + "pub union Found[T] {\n" + "  case Hit(v: T)\n" + "  case Miss\n" + "}\n" + "\n" +
        "pub union Effect[Msg] {\n" +
        "  case Go(url: String)\n" +
        "  case Stay\n" +
        "  case Ask(q: String, yes: Msg)\n" +
        "}\n" +
        "\n" +
        "pub record Program[E, Msg] {\n" +
        "  classify: (E) -> Found[Effect[Msg]]\n" +
        "}\n" +
        "\n" +
        "pub func describe[E, Msg](p: in Program[E, Msg], xs: in List[E]): String {\n" +
        "  var acc = \"\"\n" +
        "  for e in xs {\n" +
        "    match p.classify(e) {\n" +
        "      case Miss -> {\n" +
        "        acc = acc + \"app;\"\n" +
        "      }\n" +
        "      case Hit(fx) -> match fx {\n" +
        "        case Go(url) -> {\n" +
        "          acc = acc + \"go \" + url + \";\"\n" +
        "        }\n" +
        "        case Stay -> {\n" +
        "          acc = acc + \"stay;\"\n" +
        "        }\n" +
        "        case Ask(q, _) -> {\n" +
        "          acc = acc + \"ask \" + q + \";\"\n" +
        "        }\n" +
        "      }\n" +
        "    }\n" +
        "  }\n" +
        "  return acc\n" +
        "}\n" +
        "\n" +
        "pub func describeFn[E, Msg](f: (E) -> Found[Effect[Msg]], xs: in List[E]): String {\n" +
        "  var acc = \"\"\n" +
        "  for e in xs {\n" +
        "    match f(e) {\n" +
        "      case Miss -> {\n" +
        "        acc = acc + \"app;\"\n" +
        "      }\n" +
        "      case Hit(fx) -> match fx {\n" +
        "        case Go(url) -> {\n" +
        "          acc = acc + \"go \" + url + \";\"\n" +
        "        }\n" +
        "        case Stay -> {\n" +
        "          acc = acc + \"stay;\"\n" +
        "        }\n" +
        "        case Ask(q, _) -> {\n" +
        "          acc = acc + \"ask \" + q + \";\"\n" +
        "        }\n" +
        "      }\n" +
        "    }\n" +
        "  }\n" +
        "  return acc\n" +
        "}\n"
    )
  )
  pkgs
}

test "emitProject generic union through a function inside an imported generic (MSIL)" {
  val result = runEmitProject("emitproj-genfx", genericFieldFnPkgs(), "EPFx")
  assertEqualInt(result.exitCode, 0, "generic fn result MSIL: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "go /a;app;stay; go /a;app;stay;", "generic fn result MSIL: output")
}

test "emitProject generic union through a function inside an imported generic (JVM)" {
  val result = runEmitProjectJvmOpts("emitproj-genfx-jvm", genericFieldFnPkgs(), "EPFx")
  assertEqualInt(result.exitCode, 0, "generic fn result JVM: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "go /a;app;stay; go /a;app;stay;", "generic fn result JVM: output")
}

// Generic union cases built inside an imported generic and stored in a typed
// list, consumer first, on both targets: a nullary case argument (`Go`) must
// bind `Msg` as a value of `Msg`, never as a zero-argument function
// reference (D-progress-951), and a case whose arguments do not pin its type
// arguments (`OnInput(toMsg = f)`) must be built at the list's element type,
// not `Handler<object>`, or the list's typed array rejects the store.
func genericHandlerPkgs(): List[Emitter.ProjectPackage] {
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(
    mkProjectPkg(
      "EPHd.App",
      "package EPHd.App\n" + "\n" + "import EPHd.Core.{Handler, OnClick, OnInput, inputHandlers, clickHandlers}\n" +
        "\n" +
        "union Msg {\n" +
        "  case Typed(s: String)\n" +
        "  case Go\n" +
        "}\n" +
        "\n" +
        "func describe(h: in Handler[Msg]): String {\n" +
        "  return match h {\n" +
        "    case OnClick(m) -> match m {\n" +
        "      case Go -> \"click go\"\n" +
        "      case Typed(s) -> \"click \" + s\n" +
        "    }\n" +
        "    case OnInput(f) -> match f(\"abc\") {\n" +
        "      case Typed(s) -> \"input \" + s\n" +
        "      case Go -> \"input go\"\n" +
        "    }\n" +
        "  }\n" +
        "}\n" +
        "\n" +
        "func main(): Unit {\n" +
        "  val cs: List[Handler[Msg]] = clickHandlers(Go)\n" +
        "  val ins: List[Handler[Msg]] = inputHandlers({ s: String -> Typed(s = s) })\n" +
        "  println(describe(cs[0]) + \"; \" + describe(ins[0]))\n" +
        "}\n"
    )
  )
  pkgs.add(
    mkProjectPkg(
      "EPHd.Core",
      "package EPHd.Core\n" + "\n" + "pub union Handler[Msg] {\n" + "  case OnClick(msg: Msg)\n" +
        "  case OnInput(toMsg: (String) -> Msg)\n" +
        "}\n" +
        "\n" +
        "pub func inputHandlers[Msg](onInput: in (String) -> Msg): List[Handler[Msg]] {\n" +
        "  val hs: List[Handler[Msg]] = newList()\n" +
        "  hs.add(OnInput(toMsg = onInput))\n" +
        "  return hs\n" +
        "}\n" +
        "\n" +
        "pub func clickHandlers[Msg](m: in Msg): List[Handler[Msg]] {\n" +
        "  val hs: List[Handler[Msg]] = newList()\n" +
        "  hs.add(OnClick(msg = m))\n" +
        "  return hs\n" +
        "}\n"
    )
  )
  pkgs
}

test "emitProject generic union cases stored in a typed list inside an imported generic (MSIL)" {
  val result = runEmitProject("emitproj-genhd", genericHandlerPkgs(), "EPHd")
  assertEqualInt(result.exitCode, 0, "generic handlers MSIL: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "click go; input abc", "generic handlers MSIL: output")
}

test "emitProject generic union cases stored in a typed list inside an imported generic (JVM)" {
  val result = runEmitProjectJvmOpts("emitproj-genhd-jvm", genericHandlerPkgs(), "EPHd")
  assertEqualInt(result.exitCode, 0, "generic handlers JVM: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "click go; input abc", "generic handlers JVM: output")
}

// A bare call inside an imported generic whose name another imported package
// also declares, at the same arity: the body was type-checked in its own
// package, where that package's declaration shadows the import, so its
// specialisation must call the same one (D-progress-954).  Before the fix the
// call bound the other package's `findAll` (invalid IL on MSIL) or stayed
// unresolved (T0123).
func ownOverloadPkgs(): List[Emitter.ProjectPackage] {
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(
    mkProjectPkg(
      "EPOv.App",
      "package EPOv.App\n" + "\n" + "import EPOv.Core.{Box, Full, Empty, Hit, Miss, findFirst}\n" +
        "import EPOv.Other\n" +
        "\n" +
        "func main(): Unit {\n" +
        "  val kids: List[Box[Int]] = newList()\n" +
        "  val b: Box[Int] = Full(value = 7, children = kids)\n" +
        "  val hit = match findFirst(b) {\n" +
        "    case Hit(x) -> match x {\n" +
        "      case Full(v, _) -> \"found \" + toString(v)\n" +
        "      case Empty -> \"found empty\"\n" +
        "    }\n" +
        "    case Miss -> \"none\"\n" +
        "  }\n" +
        "  println(hit + \"; \" + EPOv.Other.findAll(\"a\", \"b\")[0])\n" +
        "}\n"
    )
  )
  pkgs.add(
    mkProjectPkg(
      "EPOv.Core",
      "package EPOv.Core\n" + "\n" + "pub enum Kind {\n" + "  case A\n" + "  case B\n" + "}\n" + "\n" +
        "pub union Box[T] {\n" +
        "  case Full(value: T, children: List[Box[T]])\n" +
        "  case Empty\n" +
        "}\n" +
        "\n" +
        "pub union Found[T] {\n" +
        "  case Hit(v: T)\n" +
        "  case Miss\n" +
        "}\n" +
        "\n" +
        "pub func findAll[T](b: in Box[T], k: in Kind): List[Box[T]] {\n" +
        "  val acc: List[Box[T]] = newList()\n" +
        "  acc.add(b)\n" +
        "  return acc\n" +
        "}\n" +
        "\n" +
        "pub func findFirst[T](b: in Box[T]): Found[Box[T]] {\n" +
        "  val all: List[Box[T]] = findAll(b, Kind.A)\n" +
        "  for x in all {\n" +
        "    val bx: Box[T] = x\n" +
        "    return Hit(v = bx)\n" +
        "  }\n" +
        "  return Miss\n" +
        "}\n"
    )
  )
  pkgs.add(
    mkProjectPkg(
      "EPOv.Other",
      "package EPOv.Other\n" + "\n" + "pub func findAll(node: in String, tag: in String): List[String] {\n" +
        "  val acc: List[String] = newList()\n" +
        "  acc.add(node + tag)\n" +
        "  return acc\n" +
        "}\n"
    )
  )
  pkgs
}

test "emitProject bare call in an imported generic prefers its own package's overload (MSIL)" {
  val result = runEmitProject("emitproj-ownov", ownOverloadPkgs(), "EPOv")
  assertEqualInt(result.exitCode, 0, "own overload MSIL: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "found 7; ab", "own overload MSIL: output")
}

test "emitProject bare call in an imported generic prefers its own package's overload (JVM)" {
  val result = runEmitProjectJvmOpts("emitproj-ownov-jvm", ownOverloadPkgs(), "EPOv")
  assertEqualInt(result.exitCode, 0, "own overload JVM: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "found 7; ab", "own overload JVM: output")
}

// Another package's function used as a value (D-progress-963): a bare
// selective import, the alias-rewritten `Other.f` spelling and the full
// package path, with value-type parameters and a parameter of a type declared
// in the function's own package.  Each becomes a typed forwarding lambda, so
// it runs on both targets.
func funcValuePkgs(): List[Emitter.ProjectPackage] {
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(
    mkProjectPkg(
      "EPFv.App",
      "package EPFv.App\n" + "\n" + "import EPFv.Other\n" + "import EPFv.Other.{joinPair, Tag}\n" + "\n" +
        "record Holder {\n" +
        "  f: (String, String) -> String\n" +
        "  g: (Int, Long) -> Long\n" +
        "  h: (Tag) -> String\n" +
        "}\n" +
        "\n" +
        "record Pipe[T] {\n" +
        "  step: (T) -> T\n" +
        "}\n" +
        "\n" +
        "func main(): Unit {\n" +
        "  val a = Holder(f = joinPair, g = Other.addN, h = EPFv.Other.tagName)\n" +
        "  val k: (String, String) -> String = EPFv.Other.joinPair\n" +
        "  val pp = Pipe(step = EPFv.Other.inc)\n" +
        "  println(a.f(\"a\", \"b\") + \" \" + toString(a.g(2, 40)) + \" \" + a.h(Tag(label = \"t\")) + \" \" + k(\"c\", \"d\") + \" \" + toString(pp.step(41)))\n" +
        "}\n"
    )
  )
  pkgs.add(
    mkProjectPkg(
      "EPFv.Other",
      "package EPFv.Other\n" + "\n" + "pub record Tag {\n" + "  label: String\n" + "}\n" + "\n" +
        "pub func joinPair(x: in String, y: in String): String {\n" +
        "  return x + y\n" +
        "}\n" +
        "\n" +
        "pub func addN(a: in Int, b: in Long): Long {\n" +
        "  return a.toLong() + b\n" +
        "}\n" +
        "\n" +
        "pub func tagName(t: in Tag): String {\n" +
        "  return \"<\" + t.label + \">\"\n" +
        "}\n" +
        "\n" +
        "pub func inc(x: in Int): Int {\n" +
        "  return x + 1\n" +
        "}\n"
    )
  )
  pkgs
}

test "emitProject another package's functions used as values (MSIL)" {
  val result = runEmitProject("emitproj-fnval", funcValuePkgs(), "EPFv")
  assertEqualInt(result.exitCode, 0, "function values MSIL: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "ab 42 <t> cd 42", "function values MSIL: output")
}

test "emitProject another package's functions used as values (JVM)" {
  val result = runEmitProjectJvmOpts("emitproj-fnval-jvm", funcValuePkgs(), "EPFv")
  assertEqualInt(result.exitCode, 0, "function values JVM: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "ab 42 <t> cd 42", "function values JVM: output")
}

// An overloaded name cannot be a function value, bare or qualified: the
// checker refuses it (T0123) instead of picking one overload (D-progress-963).
func overloadedValuePkgs(useBare: in Bool): List[Emitter.ProjectPackage] {
  val ref = if useBare { "pad" } else { "EPOl.Other.pad" }
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(
    mkProjectPkg(
      "EPOl.App",
      "package EPOl.App\n" + "\n" + "import EPOl.Other\n" + "import EPOl.Other.{pad}\n" + "\n" + "func main(): Unit {\n" +
        "  val f: (String) -> String = " +
        ref +
        "\n" +
        "  println(f(\"x\"))\n" +
        "}\n"
    )
  )
  pkgs.add(
    mkProjectPkg(
      "EPOl.Other",
      "package EPOl.Other\n" + "\n" + "pub func pad(s: in String, n: in Int): String { s + n.toString() }\n" + "\n" +
        "pub func pad(s: in String): String { s + \" \" }\n"
    )
  )
  pkgs
}

func emitProjectFails(label: in String, pkgs: in List[Emitter.ProjectPackage], asm: in String): Bool {
  val dir = freshTempDir(label)
  val req = Emitter.EmitProjectRequest(
    packages = pkgs,
    assemblyName = asm,
    outputPath = Path.join(dir, asm + ".dll"),
    target = Emitter.Dotnet,
    restoredDllPaths = newList(),
    activeFeatures = newList(),
    declaredFeatures = newList(),
    packageVersion = "",
    depTemplateSrcs = newList(),
    nugetAssemblyPaths = newList(),
    defines = newList()
  )
  val failed = match Emitter.emitProject(req).outputPath { case None -> true; case Some(_) -> false }
  cleanup(dir)
  failed
}

// End to end, the project build is refused. `emitProject` reports only the
// B0001 wrapper (the type checker's diagnostics go to stderr), so the T0123
// code itself is asserted by typechecker_self_test.l's "overloaded function
// value" case.
test "emitProject refuses an overloaded function as a value (T0123)" {
  assertTrue(
    emitProjectFails("emitproj-fnval-ovl-bare", overloadedValuePkgs(true), "EPOl"),
    "bare overloaded name refused"
  )
  assertTrue(
    emitProjectFails("emitproj-fnval-ovl-qual", overloadedValuePkgs(false), "EPOl"),
    "qualified overloaded name refused"
  )
}

// An unannotated generic record built from another package's function
// (`val p = Program(update = Logic.update)`) is constructed at the type mono
// infers for it, and a generic taking it specialises and runs; before, MSIL
// built `Program<object, object>` and the specialised call's cast failed
// (D-progress-963).
func funcValueRecordPkgs(): List[Emitter.ProjectPackage] {
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(
    mkProjectPkg(
      "EPCh.App",
      "package EPCh.App\n" + "\n" + "import EPCh.Session\n" + "import EPCh.Session.{Program, handle, click}\n" +
        "import EPCh.Logic\n" +
        "import EPCh.Logic.{Inc}\n" +
        "\n" +
        "func main(): Unit {\n" +
        "  val p = Program(update = Logic.update)\n" +
        "  println(toString(handle(p, 41, click(Inc))))\n" +
        "}\n"
    )
  )
  pkgs.add(
    mkProjectPkg(
      "EPCh.Core",
      "package EPCh.Core\n" + "\n" + "pub union Handler[Msg] {\n" + "  case OnClick(msg: Msg)\n" +
        "  case OnInput(toMsg: (String) -> Msg)\n" +
        "}\n" +
        "\n" +
        "pub func fire[Msg](h: in Handler[Msg], data: in String): Msg {\n" +
        "  return match h {\n" +
        "    case OnClick(m) -> m\n" +
        "    case OnInput(f) -> f(data)\n" +
        "  }\n" +
        "}\n"
    )
  )
  pkgs.add(
    mkProjectPkg(
      "EPCh.Session",
      "package EPCh.Session\n" + "\n" + "import EPCh.Core.{Handler, OnClick, fire}\n" + "\n" +
        "pub union SessionMsg[Msg] {\n" +
        "  case App(msg: Msg)\n" +
        "  case Answer(yes: Bool)\n" +
        "}\n" +
        "\n" +
        "pub record Program[M, Msg] {\n" +
        "  update: (M, Msg) -> M\n" +
        "}\n" +
        "\n" +
        "pub func handle[M, Msg](p: in Program[M, Msg], model: in M, h: in Handler[SessionMsg[Msg]]): M {\n" +
        "  val fired: SessionMsg[Msg] = fire(h, \"x\")\n" +
        "  return match fired {\n" +
        "    case App(m) -> p.update(model, m)\n" +
        "    case Answer(_) -> model\n" +
        "  }\n" +
        "}\n" +
        "\n" +
        "pub func click[Msg](m: in Msg): Handler[SessionMsg[Msg]] {\n" +
        "  return OnClick(msg = App(msg = m))\n" +
        "}\n"
    )
  )
  pkgs.add(
    mkProjectPkg(
      "EPCh.Logic",
      "package EPCh.Logic\n" + "\n" + "pub union Msg {\n" + "  case Inc\n" + "  case Dec\n" + "}\n" + "\n" +
        "pub func update(model: in Int, msg: in Msg): Int {\n" +
        "  return match msg {\n" +
        "    case Inc -> model + 1\n" +
        "    case Dec -> model - 1\n" +
        "  }\n" +
        "}\n"
    )
  )
  pkgs
}

test "emitProject a generic record built from another package's function (MSIL)" {
  val result = runEmitProject("emitproj-fnrec", funcValueRecordPkgs(), "EPCh")
  assertEqualInt(result.exitCode, 0, "function-value record MSIL: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "42", "function-value record MSIL: output")
}

test "emitProject a generic record built from another package's function (JVM)" {
  val result = runEmitProjectJvmOpts("emitproj-fnrec-jvm", funcValueRecordPkgs(), "EPCh")
  assertEqualInt(result.exitCode, 0, "function-value record JVM: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "42", "function-value record JVM: output")
}

// A specialised copy of another package's generic resolves its bare type
// names in that package's scope (D-progress-967).  `EPHs.Core.fire` matches on
// its own `Handler` union, specialised into a consumer that imports an
// unrelated `EPHs.Web.Handler` interface; resolved in the consumer's scope,
// the pattern bound nothing (T0115 on `m`).
func typeScopePkgs(): List[Emitter.ProjectPackage] {
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(
    mkProjectPkg(
      "EPHs.App",
      "package EPHs.App\n" + "\n" + "import EPHs.Web.{Handler}\n" + "import EPHs.Session.{handle, click}\n" + "\n" +
        "record Greeter {\n" +
        "  n: Int\n" +
        "}\n" +
        "\n" +
        "impl Handler for Greeter {\n" +
        "  func respond(): Int {\n" +
        "    return self.n\n" +
        "  }\n" +
        "}\n" +
        "\n" +
        "func main(): Unit {\n" +
        "  val g = Greeter(n = 1)\n" +
        "  println(toString(handle(41, click(g.respond()))))\n" +
        "}\n"
    )
  )
  pkgs.add(
    mkProjectPkg(
      "EPHs.Core",
      "package EPHs.Core\n" + "\n" + "pub union Handler[Msg] {\n" + "  case OnClick(msg: Msg)\n" +
        "  case OnInput(toMsg: (String) -> Msg)\n" +
        "}\n" +
        "\n" +
        "pub func fire[Msg](h: in Handler[Msg], data: in String): Msg {\n" +
        "  return match h {\n" +
        "    case OnClick(m) -> m\n" +
        "    case OnInput(f) -> f(data)\n" +
        "  }\n" +
        "}\n"
    )
  )
  pkgs.add(
    mkProjectPkg(
      "EPHs.Session",
      "package EPHs.Session\n" + "\n" + "import EPHs.Core.{Handler, OnClick, fire}\n" + "\n" +
        "pub func handle[Msg](base: in Int, h: in Handler[Msg]): Int {\n" +
        "  val fired: Msg = fire(h, \"x\")\n" +
        "  return base + 1\n" +
        "}\n" +
        "\n" +
        "pub func click[Msg](m: in Msg): Handler[Msg] {\n" +
        "  return OnClick(msg = m)\n" +
        "}\n"
    )
  )
  pkgs.add(
    mkProjectPkg(
      "EPHs.Web",
      "package EPHs.Web\n" + "\n" + "pub interface Handler {\n" + "  func respond(): Int\n" + "}\n"
    )
  )
  pkgs
}

test "emitProject an imported generic resolves its type names in its own package (MSIL)" {
  val result = runEmitProject("emitproj-tyscope", typeScopePkgs(), "EPHs")
  assertEqualInt(result.exitCode, 0, "type scope MSIL: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "42", "type scope MSIL: output")
}

test "emitProject an imported generic resolves its type names in its own package (JVM)" {
  val result = runEmitProjectJvmOpts("emitproj-tyscope-jvm", typeScopePkgs(), "EPHs")
  assertEqualInt(result.exitCode, 0, "type scope JVM: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "42", "type scope JVM: output")
}

// Constructing another package's `protected type` (D-progress-980).  MSIL
// registered every nominal type name for cross-package resolution except
// protected types, so `Counter()` in a consumer failed with T0123.
func protectedCtorPkgs(): List[Emitter.ProjectPackage] {
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(
    mkProjectPkg(
      "EPPt.App",
      "package EPPt.App\n" + "\n" + "import EPPt.Lib.{Counter}\n" + "\n" + "func main(): Unit {\n" +
        "  val c = Counter()\n" +
        "  c.bump()\n" +
        "  c.bump()\n" +
        "  println(toString(c.get()))\n" +
        "}\n"
    )
  )
  pkgs.add(
    mkProjectPkg(
      "EPPt.Lib",
      "package EPPt.Lib\n" + "\n" + "pub protected type Counter {\n" + "  var n: Int = 40\n" +
        "  entry bump(): Unit {\n" +
        "    n = n + 1\n" +
        "  }\n" +
        "  func get(): Int {\n" +
        "    return n\n" +
        "  }\n" +
        "}\n"
    )
  )
  pkgs
}

test "emitProject constructs another package's protected type (MSIL)" {
  val result = runEmitProject("emitproj-protctor", protectedCtorPkgs(), "EPPt")
  assertEqualInt(result.exitCode, 0, "protected ctor MSIL: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "42", "protected ctor MSIL: output")
}

test "emitProject constructs another package's protected type (JVM)" {
  val result = runEmitProjectJvmOpts("emitproj-protctor-jvm", protectedCtorPkgs(), "EPPt")
  assertEqualInt(result.exitCode, 0, "protected ctor JVM: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "42", "protected ctor JVM: output")
}

// A generic record's type parameter named like a type of the constructing
// package (`Msg`): each constructor argument must be checked against the
// field type with the record's own parameters in scope (D-progress-980).
func genericParamShadowPkgs(): List[Emitter.ProjectPackage] {
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(
    mkProjectPkg(
      "EPGs.App",
      "package EPGs.App\n" + "\n" + "import EPGs.Lib.{Prog, runOnce}\n" + "\n" + "union Msg {\n" + "  case Inc\n" +
        "}\n" +
        "\n" +
        "union Other {\n" +
        "  case Dec\n" +
        "}\n" +
        "\n" +
        "func stepA(m: in Int, msg: in Msg): Int {\n" +
        "  return m + 1\n" +
        "}\n" +
        "\n" +
        "func stepB(m: in Int, o: in Other): Int {\n" +
        "  return m + 40\n" +
        "}\n" +
        "\n" +
        "func main(): Unit {\n" +
        "  val a: Prog[Int, Msg] = Prog(step = stepA)\n" +
        "  val b: Prog[Int, Other] = Prog(step = stepB)\n" +
        "  println(toString(runOnce(b, runOnce(a, 1, Inc), Dec)))\n" +
        "}\n"
    )
  )
  pkgs.add(
    mkProjectPkg(
      "EPGs.Lib",
      "package EPGs.Lib\n" + "\n" + "pub record Prog[M, Msg] {\n" + "  step: (M, Msg) -> M\n" + "}\n" + "\n" +
        "pub func runOnce[M, Msg](p: in Prog[M, Msg], m: in M, msg: in Msg): M {\n" +
        "  return p.step(m, msg)\n" +
        "}\n"
    )
  )
  pkgs
}

test "emitProject a generic record parameter named like a consumer type (MSIL)" {
  val result = runEmitProject("emitproj-gshadow", genericParamShadowPkgs(), "EPGs")
  assertEqualInt(result.exitCode, 0, "generic param shadow MSIL: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "42", "generic param shadow MSIL: output")
}

test "emitProject a generic record parameter named like a consumer type (JVM)" {
  val result = runEmitProjectJvmOpts("emitproj-gshadow-jvm", genericParamShadowPkgs(), "EPGs")
  assertEqualInt(result.exitCode, 0, "generic param shadow JVM: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "42", "generic param shadow JVM: output")
}

// A generic record whose field names a type of its own package while the
// constructing package declares a same-named type: the field type resolves
// in the declaring package's scope (#6689, #7391).
func genericFieldScopePkgs(): List[Emitter.ProjectPackage] {
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(
    mkProjectPkg(
      "EPGf.App",
      "package EPGf.App\n" + "\n" + "import EPGf.Lib.{Tagged, mkItem, total}\n" + "\n" + "record Item {\n" +
        "  s: String\n" +
        "}\n" +
        "\n" +
        "func main(): Unit {\n" +
        "  val local = Item(s = \"x\")\n" +
        "  val t: Tagged[Int] = Tagged(item = mkItem(40), value = 2)\n" +
        "  println(toString(total(t)))\n" +
        "}\n"
    )
  )
  pkgs.add(
    mkProjectPkg(
      "EPGf.Lib",
      "package EPGf.Lib\n" + "\n" + "pub record Item {\n" + "  n: Int\n" + "}\n" + "\n" + "pub record Tagged[T] {\n" +
        "  item: Item\n" +
        "  value: T\n" +
        "}\n" +
        "\n" +
        "pub func mkItem(n: in Int): Item {\n" +
        "  return Item(n = n)\n" +
        "}\n" +
        "\n" +
        "pub func total(t: in Tagged[Int]): Int {\n" +
        "  return t.item.n + t.value\n" +
        "}\n"
    )
  )
  pkgs
}

test "emitProject a generic record field names its own package's type (MSIL)" {
  val result = runEmitProject("emitproj-gfscope", genericFieldScopePkgs(), "EPGf")
  assertEqualInt(result.exitCode, 0, "generic field scope MSIL: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "42", "generic field scope MSIL: output")
}

test "emitProject a generic record field names its own package's type (JVM)" {
  val result = runEmitProjectJvmOpts("emitproj-gfscope-jvm", genericFieldScopePkgs(), "EPGf")
  assertEqualInt(result.exitCode, 0, "generic field scope JVM: exit 0 (stderr=" + result.stderr + ")")
  assertEqual(Str.trim(result.stdout), "42", "generic field scope JVM: output")
}
