//! msil_restored_qualified_val_self_test.l — regression tests for #6133 /
//! #5275: a QUALIFIED reference (`Pkg.NAME`) to a restored dependency's
//! module-level `pub val` across a real assembly boundary.
//!
//! Before this fix, `tryQualifiedStaticValNameMsil` only ever checked
//! `staticValTokens` (this bundle's own compiled statics), never
//! `constValues` (where a restored artifact's literal-foldable `pub val`s
//! are registered, #2592 slice 1) — so a QUALIFIED reference to a restored
//! literal fell through to the generic `EMember`/`EPath` fallback chain and
//! silently evaluated to `null`/an uninitialised int at runtime, even though
//! the identical UNQUALIFIED (bare, after `import Pkg`) reference already
//! correctly inlined the value. A restored dependency's NON-literal `pub val`
//! (no contract-metadata repr at all, #5258's documented residual gap) hit
//! the exact same silent-null fallback with no compile-time diagnostic
//! whatsoever, in either qualified or unqualified form.
//!
//! This fixes the qualified-literal case for real (a package-qualified
//! `constValues` key, mirroring `staticValTokens`'s existing convention) and
//! converts the non-literal case into a loud compile-time `error[T0115]`
//! instead of a silent wrong-value read (the sanctioned fail-loudly stopgap
//! — see #6133's triage comment; a full fix needs a contract-metadata schema
//! change, tracked in docs/45 and gated on #2580).
//!
//! Each test builds a PRODUCER DLL in-process via `Lyric.Emitter.emitProject`,
//! then a CONSUMER that imports the producer as a restored dep — the same
//! two-stage harness as `restored_async_self_test.l` /
//! `cross_package_generics_self_test.l`.
//!
//! Run via native `lyric test` with LYRIC_LOAD_COMPILER=1 (required because
//! the test imports `Lyric.Emitter`, a compiler package):
//!   LYRIC_LOAD_COMPILER=1 lyric test lyric-compiler/lyric/msil_restored_qualified_val_self_test.l
//!
@test_module
package Lyric.MsilRestoredQualifiedValSelfTest

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

// ─── Helpers (same shape as restored_async_self_test.l) ──────────────────────
func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", Environment.getVarOrDefault("TEMP", Environment.getVarOrDefault("TMP", "/tmp")))
}

func freshTempDir(label: in String): String {
  val root = Path.join(tempBase(), "lyric-msilqval-" + label + "-" + uuidToString(newUuid()))
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

func mkPkg(name: in String, source: in String): Emitter.ProjectPackage {
  val srcs: List[String] = newList()
  srcs.add(source)
  Emitter.ProjectPackage(name = name, sources = srcs)
}

func buildDll(tmpDir: in String, pkgName: in String, source: in String, asmName: in String): String {
  val dllPath = Path.join(tmpDir, asmName + ".dll")
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(mkPkg(pkgName, source))
  val req = Emitter.EmitProjectRequest(
    packages = pkgs,
    assemblyName = asmName,
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
    case None -> panic("buildDll(" + asmName + "): compilation failed")
    case Some(_) -> ()
  }
  dllPath
}

// Build a consumer DLL whose restoredDllPaths contains producerDllPath.
// Does NOT panic on a compile failure — returns the raw EmitResult so
// callers can assert on failure diagnostics (the #6133 stopgap case).
func buildConsumerResult(
  tmpDir: in String,
  consumerPkgName: in String,
  consumerSource: in String,
  consumerAsmName: in String,
  producerPkgName: in String,
  producerDllPath: in String,
): Emitter.EmitResult {
  val dllPath = Path.join(tmpDir, consumerAsmName + ".dll")
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(mkPkg(consumerPkgName, consumerSource))
  val restored: List[String] = newList()
  restored.add(producerPkgName + "\t" + producerDllPath)
  val req = Emitter.EmitProjectRequest(
    packages = pkgs,
    assemblyName = consumerAsmName,
    outputPath = dllPath,
    target = Emitter.Dotnet,
    restoredDllPaths = restored,
    activeFeatures = newList(),
    declaredFeatures = newList(),
    packageVersion = "",
    depTemplateSrcs = newList(),
    nugetAssemblyPaths = newList(),
    defines = newList()
  )
  Emitter.emitProject(req)
}

func buildAndRunConsumer(
  tmpDir: in String,
  consumerPkgName: in String,
  consumerSource: in String,
  consumerAsmName: in String,
  producerPkgName: in String,
  producerDllPath: in String,
): Capture.CaptureResult {
  val dllPath = Path.join(tmpDir, consumerAsmName + ".dll")
  val result = buildConsumerResult(
    tmpDir,
    consumerPkgName,
    consumerSource,
    consumerAsmName,
    producerPkgName,
    producerDllPath
  )
  match result.outputPath {
    case None -> panic("buildAndRunConsumer(" + consumerAsmName + "): compilation failed")
    case Some(_) -> ()
  }
  writeRuntimeConfig(dllPath)
  val args: List[String] = newList()
  args.add("exec")
  args.add(dllPath)
  Capture.runCaptureWithDiagnostics("dotnet", args, "")
}

func producerSource(pkg: in String): String {
  "package " + pkg + "\n" + "\n" + "pub val literalAnswer: Int = 42\n" + "\n" +
    "pub val nonLiteralAnswer: Int = 0 - 1\n"
}

// ─── Tests ───────────────────────────────────────────────────────────────────
// The real fix: a QUALIFIED reference to a restored dep's literal-foldable
// `pub val` must inline the correct value, not silently read null/0.
test "qualified reference to a restored literal-foldable pub val inlines correctly" {
  val tmpDir = freshTempDir("qual-literal")
  val producerDll = buildDll(tmpDir, "MsilQVal.Lib", producerSource("MsilQVal.Lib"), "MsilQVal.Lib")
  val consumerSrc = "package MsilQVal.App\n" + "\n" + "import MsilQVal.Lib\n" + "\n" + "func main(): Unit {\n" +
    "  println(MsilQVal.Lib.literalAnswer)\n" +
    "}\n"
  val captured = buildAndRunConsumer(tmpDir, "MsilQVal.App", consumerSrc, "MsilQVal.App", "MsilQVal.Lib", producerDll)
  cleanup(tmpDir)
  assertEqualInt(captured.exitCode, 0, "qual-literal: exit 0 (stderr=" + captured.stderr + ")")
  assertEqual(Str.trim(captured.stdout), "42", "qual-literal: stdout = 42, not null/0 (#6133)")
}

// The stopgap: a QUALIFIED reference to a restored dep's NON-literal
// `pub val` must fail to compile with the new diagnostic, not silently
// compile to a null/0 read.
test "qualified reference to a restored non-literal pub val fails to compile with T0115, not a silent null read" {
  val tmpDir = freshTempDir("qual-nonliteral")
  val producerDll = buildDll(tmpDir, "MsilQVal.NlLib", producerSource("MsilQVal.NlLib"), "MsilQVal.NlLib")
  val consumerSrc = "package MsilQVal.NlApp\n" + "\n" + "import MsilQVal.NlLib\n" + "\n" + "func main(): Unit {\n" +
    "  println(MsilQVal.NlLib.nonLiteralAnswer)\n" +
    "}\n"
  var panicked = false
  var caughtMessage = ""
  try {
    buildConsumerResult(tmpDir, "MsilQVal.NlApp", consumerSrc, "MsilQVal.NlApp", "MsilQVal.NlLib", producerDll)
  } catch Bug as b {
    panicked = true
    caughtMessage = b.message
  }
  cleanup(tmpDir)
  assertTrue(
    panicked,
    "qual-nonliteral: compilation must abort instead of silently compiling a null/0 read (#6133/#5275)"
  )
  assertTrue(
    Str.contains(caughtMessage, "T0115"),
    "qual-nonliteral: diagnostic carries the T0115 code (got: " + caughtMessage + ")"
  )
  assertTrue(
    Str.contains(caughtMessage, "MsilQVal.NlLib.nonLiteralAnswer"),
    "qual-nonliteral: diagnostic names the unresolved qualified reference (got: " + caughtMessage + ")"
  )
}

// Regression guard: further field/method access chained on TOP of a
// restored qualified literal (e.g. calling `.toString()` on it) must still
// resolve through the qualified value, not misfire the new T0115 check —
// mirrors msil_project_bridge_self_test.l's in-bundle "multi-segment
// qualified static val resolves correctly" case, but across a genuine
// restored-DLL boundary.
test "chained member access on a restored qualified literal still resolves (no T0115 false positive)" {
  val tmpDir = freshTempDir("qual-chained")
  val producerDll = buildDll(tmpDir, "MsilQVal.ChLib", producerSource("MsilQVal.ChLib"), "MsilQVal.ChLib")
  val consumerSrc = "package MsilQVal.ChApp\n" + "\n" + "import MsilQVal.ChLib\n" + "\n" + "func main(): Unit {\n" +
    "  println(MsilQVal.ChLib.literalAnswer.toString())\n" +
    "}\n"
  val captured = buildAndRunConsumer(
    tmpDir,
    "MsilQVal.ChApp",
    consumerSrc,
    "MsilQVal.ChApp",
    "MsilQVal.ChLib",
    producerDll
  )
  cleanup(tmpDir)
  assertEqualInt(captured.exitCode, 0, "qual-chained: exit 0 (stderr=" + captured.stderr + ")")
  assertEqual(
    Str.trim(captured.stdout),
    "42",
    "qual-chained: stdout = 42 via .toString() chained on the qualified value"
  )
}

// Baseline sanity: the UNQUALIFIED (bare) form already worked before this
// fix (#2592 slice 1) and must keep working.
test "bare (unqualified) reference to a restored literal-foldable pub val still inlines correctly" {
  val tmpDir = freshTempDir("bare-literal")
  val producerDll = buildDll(tmpDir, "MsilQVal.BareLib", producerSource("MsilQVal.BareLib"), "MsilQVal.BareLib")
  val consumerSrc = "package MsilQVal.BareApp\n" + "\n" + "import MsilQVal.BareLib\n" + "\n" + "func main(): Unit {\n" +
    "  println(literalAnswer)\n" +
    "}\n"
  val captured = buildAndRunConsumer(
    tmpDir,
    "MsilQVal.BareApp",
    consumerSrc,
    "MsilQVal.BareApp",
    "MsilQVal.BareLib",
    producerDll
  )
  cleanup(tmpDir)
  assertEqualInt(captured.exitCode, 0, "bare-literal: exit 0 (stderr=" + captured.stderr + ")")
  assertEqual(Str.trim(captured.stdout), "42", "bare-literal: stdout = 42 (regression guard for #2592 slice 1)")
}
