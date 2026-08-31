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
  Emitter.ProjectPackage(name = name, sources = srcs)
}

func mkProjectPkgMulti(name: in String, sources: in List[String]): Emitter.ProjectPackage {
  Emitter.ProjectPackage(name = name, sources = sources)
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
  pkgs.add(Emitter.ProjectPackage(name = "MDir", sources = sources))
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
  pkgs.add(Emitter.ProjectPackage(name = "MDirJvm", sources = sources))
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
test "emit(target = Jvm) contains a codegen-refusal Bug as an EmitResult failure, not a thrown exception (#6422)" {
  val dir = freshTempDir("jvm-contain-j007")
  val source = "package ContainJ007.App\n" + "\n" + "record Widget {\n" + "  n: Int\n" + "}\n" + "\n" +
    "union Box[T] {\n" +
    "  case Full(value: T)\n" +
    "  case Empty\n" +
    "}\n" +
    "\n" +
    "record Holder {\n" +
    "  box: Box[Widget]\n" +
    "}\n" +
    "\n" +
    "func unwrap(h: Holder): Int {\n" +
    "  match h.box {\n" +
    "    case Full(w) -> w.n\n" +
    "    case Empty -> 0\n" +
    "  }\n" +
    "}\n" +
    "\n" +
    "func main(): Unit {\n" +
    "  println(unwrap(Holder(box = Full(value = Widget(n = 40)))))\n" +
    "}\n"
  val noDefines: List[String] = newList()
  val req = Emitter.EmitRequest(
    source = source,
    assemblyName = "ContainJ007",
    outputPath = Path.join(dir, "ContainJ007.jar"),
    target = Emitter.Jvm,
    packageVersion = "",
    defines = noDefines
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
  // message embeds (`ContainJ007.App:18:21` — the `w` receiver of `w.n` in
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
      18,
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
    case Some(sp) -> assertTrue(false, "T0115 carries no location; parsePanicSpan must return None, not a spurious match (got line " + toString(sp.startPos.line) + ")")
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
    defines = noDefines
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
    defines = noDefines
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
