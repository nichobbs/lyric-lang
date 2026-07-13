//! nat_cross_package_self_test.l — regression test for a `Nat`-backed range
//! subtype crossing a restored-package boundary as a function
//! parameter/return.
//!
//! Before this fix, `typeExprToMsilCtx` (`msil/codegen.l`) had no arm for the
//! `Nat` primitive: it fell through to the generic case and encoded `Nat` as
//! `MClass("<pkg>.Nat")`, i.e. an in-package reference-type class, instead of
//! its real representation (a non-negative `Long`, docs/01 §2 "Nat"). The
//! `TRefined` arm recurses into this same function against the refinement's
//! underlying type (`msil/codegen.l`, `case TRefined(underlying, _) ->
//! typeExprToMsilCtx(...)`), so every `Nat range A ..= B` value hit the same
//! bogus encoding. Inside a single compilation unit this is at least
//! self-consistent between caller and callee IL, so it can silently build and
//! even run — `range_subtype_self_test.l` only exercises Int-/Long-backed
//! ranges in one file, so it never caught this. Across a restored-package
//! boundary the consumer instead decodes the producer's real (`I8`) signature
//! from metadata, so the two independently-derived encodings diverge and the
//! call site crashes with `InvalidProgramException` — the same failure shape
//! reported for `Web.Request` construction (docs/03-decision-log.md
//! D-progress-663), but triggered purely by a `Nat`-backed parameter, with no
//! Web involved.
//!
//! `Nat` now maps to `MLong` in `typeExprToMsilCtx` (mirrored as `JLong` in
//! the JVM backend's `typeExprToJvm`, `jvm/codegen/01_types.l`, for parity —
//! not separately exercised here; see cross_package_generics_self_test.l for
//! the established MSIL-only restored-dependency harness this file follows).
//!
//! Values are constructed via the `Type.from(x)` / `.toInt()` intrinsics
//! (the same pattern `range_subtype_self_test.l` uses for Int-/Long-backed
//! ranges) rather than a bare `Nat`-typed literal: unsuffixed integer
//! literals only adopt a non-`Int` concrete type inside a binary operator
//! (`typechecker_exprs.l`'s `adoptIntLiteralType`, wired solely into
//! `inferBinop`) or an if/match branch, never at a binding, call-argument, or
//! return position — so a bare `Nat`-typed parameter/binding cannot be
//! constructed directly from a literal today. That gap is real but distinct
//! from (and out of scope for) the MSIL/JVM signature-encoding crash this
//! file regression-tests.
//!
//! Run via native `lyric test` with LYRIC_LOAD_COMPILER=1 (required because
//! the test imports `Lyric.Emitter`, a compiler package):
//!   LYRIC_LOAD_COMPILER=1 lyric test lyric-compiler/lyric/nat_cross_package_self_test.l
//!
@test_module
package Lyric.NatCrossPackageSelfTest

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

// ─── Helpers (mirrors cross_package_generics_self_test.l) ─────────────────────
func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", Environment.getVarOrDefault("TEMP", Environment.getVarOrDefault("TMP", "/tmp")))
}

func freshTempDir(label: in String): String {
  val root = Path.join(tempBase(), "lyric-natxp-" + label + "-" + uuidToString(newUuid()))
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

// Build a DLL from a single-package source and return its path.
// Panics if compilation fails.
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
    nugetAssemblyPaths = newList()
  )
  val result = Emitter.emitProject(req)
  match result.outputPath {
    case None -> panic("buildDll(" + asmName + "): compilation failed")
    case Some(_) -> ()
  }
  dllPath
}

// Build and run a consumer DLL whose restoredDllPaths contains producerDllPath.
func buildAndRunConsumer(
  tmpDir: in String,
  consumerPkgName: in String,
  consumerSource: in String,
  consumerAsmName: in String,
  producerPkgName: in String,
  producerDllPath: in String,
): Capture.CaptureResult {
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
    nugetAssemblyPaths = newList()
  )
  val result = Emitter.emitProject(req)
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

// ─── Tests ───────────────────────────────────────────────────────────────────
// A restored `func bumpScore(s: in Score): Score` — Score = `Nat range 0 ..=
// 1000000` — parameter/return round-trip. Before the fix this crashed the
// consumer at the call site with InvalidProgramException.
test "cross-package Nat-backed range-subtype parameter and return round-trip" {
  val tmpDir = freshTempDir("nat-score")
  val producerSrc = "package NatXp.Lib\n" + "\n" + "pub type Score = Nat range 0 ..= 1000000\n" + "\n" +
    "pub func bumpScore(s: in Score): Score {\n" + "  Score.from(s.toInt() + 1)\n" + "}\n"
  val producerDll = buildDll(tmpDir, "NatXp.Lib", producerSrc, "NatXp.Lib")
  val consumerSrc = "package NatXp.App\n" + "\n" + "import NatXp.Lib\n" + "\n" + "func main(): Unit {\n" +
    "  val s = Score.from(41)\n" + "  val s2 = bumpScore(s)\n" + "  println(s2.toInt())\n" + "}\n"
  val captured = buildAndRunConsumer(tmpDir, "NatXp.App", consumerSrc, "NatXp.App", "NatXp.Lib", producerDll)
  cleanup(tmpDir)
  assertEqualInt(captured.exitCode, 0, "natxp_score: exit 0 (stderr=" + captured.stderr + ")")
  assertEqual(Str.trim(captured.stdout), "42", "natxp_score: stdout = 42")
}

// A restored record with a `Nat range`-typed field, constructed and read
// across the package boundary — the same "field/param signature encoded as a
// bogus in-package class" shape as the Web.Request InvalidProgramException
// crash.
test "cross-package record with Nat-backed range field construct and read" {
  val tmpDir = freshTempDir("nat-rec")
  val producerSrc = "package NatXp.RecLib\n" + "\n" + "pub type Score = Nat range 0 ..= 1000000\n" + "\n" +
    "pub record Counter { score: Score }\n" + "\n" +
    "pub func bumpCounter(c: in Counter): Counter {\n" +
    "  Counter(score = Score.from(c.score.toInt() + 1))\n" + "}\n"
  val producerDll = buildDll(tmpDir, "NatXp.RecLib", producerSrc, "NatXp.RecLib")
  val consumerSrc = "package NatXp.RecApp\n" + "\n" + "import NatXp.RecLib\n" + "\n" + "func main(): Unit {\n" +
    "  val c = Counter(score = Score.from(9))\n" + "  val c2 = bumpCounter(c)\n" +
    "  println(c2.score.toInt())\n" + "}\n"
  val captured = buildAndRunConsumer(tmpDir, "NatXp.RecApp", consumerSrc, "NatXp.RecApp", "NatXp.RecLib", producerDll)
  cleanup(tmpDir)
  assertEqualInt(captured.exitCode, 0, "natxp_rec: exit 0 (stderr=" + captured.stderr + ")")
  assertEqual(Str.trim(captured.stdout), "10", "natxp_rec: stdout = 10")
}
