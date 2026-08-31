//! jvm/cross_package_generics_jvm_self_test.l — regression tests for
//! user-defined generic records and unions consumed from a restored
//! (pre-compiled) JVM package (#3094, the JVM counterpart of #1496 /
//! `Lyric.CrossPackageGenericsSelfTest`).
//!
//! Prior to this fix the self-hosted JVM bridge (`Jvm.Bridge`) had no
//! restored-dependency pipeline at all: `compileToJarBundledWithFeatures`
//! only ever bundled stdlib + the user's own source, with no way to
//! consume a separately-compiled producer JAR.  This module builds a
//! PRODUCER JAR (generic record / union) via `Jvm.Bridge.compileToJarBundled`
//! (through `Lyric.Emitter.emitProject` with `target = Jvm`, exactly the
//! production entry point `lyric build --target jvm` uses), then builds a
//! CONSUMER JAR that imports the producer as a restored dep
//! (`EmitProjectRequest.restoredDllPaths`), runs it under `java`, and
//! asserts the printed output.
//!
//! The restored dep round-trip:
//!   1. The producer JAR embeds its own `Lyric.Contract.<Pkg>` JSON as a
//!      ZIP entry (`Jvm.Bridge`'s contract-embedding step).
//!   2. `Lyric.RestoredPackages.loadRestoredPackageJvm` reads it back via
//!      `Lyric.ContractMeta.readAllContractsFromJarFile`'s ZIP central
//!      directory walk (`Jvm.ZipReader`) instead of a .NET PE resource.
//!   3. `Lyric.RestoredPackages.synthesiseArtifact` re-parses the
//!      contract's `repr` strings into a `SourceFile` — shared, unchanged
//!      code between the MSIL and JVM restored-dep paths.
//!   4. `Jvm.Bridge` registers that `SourceFile`'s records/unions/functions
//!      into the SAME cross-package registries a stdlib file feeds
//!      (erased-`Object` fields — no MSIL-style arity-suffixed TypeRef /
//!      VAR-form metadata maps needed), without bundling its bytecode.
//!   5. The producer JAR's absolute path rides the consumer's manifest
//!      `Class-Path:` attribute so `java -jar consumer.jar` can load the
//!      producer's classes at runtime.
//!
//! Run via native `lyric test` with LYRIC_LOAD_COMPILER=1 (required
//! because the test imports `Lyric.Emitter`, a compiler package):
//!   LYRIC_LOAD_COMPILER=1 lyric test lyric-compiler/jvm/cross_package_generics_jvm_self_test.l
@test_module
package Jvm.CrossPackageGenericsJvmSelfTest

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

// ─── Helpers ─────────────────────────────────────────────────────────────────
func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", Environment.getVarOrDefault("TEMP", Environment.getVarOrDefault("TMP", "/tmp")))
}

func freshTempDir(label: in String): String {
  val root = Path.join(tempBase(), "lyric-cpgen-jvm-" + label + "-" + uuidToString(newUuid()))
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

func mkPkg(name: in String, source: in String): Emitter.ProjectPackage {
  val srcs: List[String] = newList()
  srcs.add(source)
  Emitter.ProjectPackage(name = name, sources = srcs)
}

// Build a JAR from a single-package source and return its path.  Panics if
// compilation fails.
func buildJar(tmpDir: in String, pkgName: in String, source: in String, jarName: in String): String {
  val jarPath = Path.join(tmpDir, jarName + ".jar")
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(mkPkg(pkgName, source))
  val req = Emitter.EmitProjectRequest(
    packages = pkgs,
    assemblyName = jarName,
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
    case None -> panic("buildJar(" + jarName + "): compilation failed")
    case Some(_) -> ()
  }
  jarPath
}

// Build and run a consumer JAR whose restoredDllPaths contains producerJarPath.
func buildAndRunConsumer(
  tmpDir: in String,
  consumerPkgName: in String,
  consumerSource: in String,
  consumerJarName: in String,
  producerPkgName: in String,
  producerJarPath: in String,
): Capture.CaptureResult {
  val jarPath = Path.join(tmpDir, consumerJarName + ".jar")
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(mkPkg(consumerPkgName, consumerSource))
  val restored: List[String] = newList()
  restored.add(producerPkgName + "\t" + producerJarPath)
  val req = Emitter.EmitProjectRequest(
    packages = pkgs,
    assemblyName = consumerJarName,
    outputPath = jarPath,
    target = Emitter.Jvm,
    restoredDllPaths = restored,
    activeFeatures = newList(),
    declaredFeatures = newList(),
    packageVersion = "",
    depTemplateSrcs = newList(),
    nugetAssemblyPaths = newList(),
    defines = newList()
  )
  val result = Emitter.emitProject(req)
  match result.outputPath {
    case None -> panic("buildAndRunConsumer(" + consumerJarName + "): compilation failed")
    case Some(_) -> ()
  }
  val args: List[String] = newList()
  args.add("-jar")
  args.add(jarPath)
  Capture.runCaptureWithDiagnostics("java", args, "")
}

// ─── Tests ───────────────────────────────────────────────────────────────────
// Generic RECORD: construct Box[Int] from a restored JAR (via a restored
// FUNCTION that builds it), read .value in the consumer.
//
// NOTE: the producer-side field read shape used by the MSIL analog
// (`pub func unboxInt(b: in Box[Int]): Int { b.value }`) hits a SEPARATE,
// pre-existing JVM backend bug unrelated to restored deps: a plain (non-
// `match`) field read on a generic record PARAMETER resolves the field by
// NAME across every bundled/stdlib type rather than by the parameter's own
// class, and `value` collides with `Std.Http.Url`'s field of the same name
// (`opaque type Url { value: String }`), producing a silent miscompile
// (`checkcast Std/Http/Url` instead of the real record class) reproducible
// even with zero restored deps. Filed as #6691 (the parameter-binding
// sibling of the return-value-binding bug #6399/#6400 already fixed); this
// test exercises restored construction + a restored function call instead,
// with the field read happening in the CONSUMER (already covered working by
// the Box[String] test below).
test "cross-package generic record Box[Int] construct and read (jvm)" {
  val tmpDir = freshTempDir("cpgen-box-int")
  val producerSrc = "package CpGenJvm.Lib\n" + "\n" + "pub record Box[T] { value: T }\n" + "\n" +
    "pub func makeBoxInt(v: in Int): Box[Int] { Box(value = v) }\n"
  val producerJar = buildJar(tmpDir, "CpGenJvm.Lib", producerSrc, "CpGenJvm.Lib")
  val consumerSrc = "package CpGenJvm.App\n" + "\n" + "import CpGenJvm.Lib\n" + "\n" + "func main(): Unit {\n" +
    "  val b = makeBoxInt(42)\n" +
    "  println(b.value)\n" +
    "}\n"
  val captured = buildAndRunConsumer(tmpDir, "CpGenJvm.App", consumerSrc, "CpGenJvm.App", "CpGenJvm.Lib", producerJar)
  cleanup(tmpDir)
  assertEqualInt(captured.exitCode, 0, "cpgen_box_int_jvm: exit 0 (stderr=" + captured.stderr + ")")
  assertEqual(Str.trim(captured.stdout), "42", "cpgen_box_int_jvm: stdout = 42")
}

// Generic RECORD: Box[String] with a reference-typed field.
test "cross-package generic record Box[String] construct and read (jvm)" {
  val tmpDir = freshTempDir("cpgen-box-str")
  val producerSrc = "package CpGenJvm.BoxStr\n" + "\n" + "pub record Box[T] { value: T }\n"
  val producerJar = buildJar(tmpDir, "CpGenJvm.BoxStr", producerSrc, "CpGenJvm.BoxStr")
  val consumerSrc = "package CpGenJvm.BoxStrApp\n" + "\n" + "import CpGenJvm.BoxStr\n" + "\n" + "func main(): Unit {\n" +
    "  val b = Box(value = \"hello\")\n" +
    "  println(b.value)\n" +
    "}\n"
  val captured = buildAndRunConsumer(
    tmpDir,
    "CpGenJvm.BoxStrApp",
    consumerSrc,
    "CpGenJvm.BoxStrApp",
    "CpGenJvm.BoxStr",
    producerJar
  )
  cleanup(tmpDir)
  assertEqualInt(captured.exitCode, 0, "cpgen_box_str_jvm: exit 0 (stderr=" + captured.stderr + ")")
  assertEqual(Str.trim(captured.stdout), "hello", "cpgen_box_str_jvm: stdout = hello")
}

// Generic RECORD: Pair[Int, String] two type parameters.
test "cross-package generic record Pair[Int,String] both fields (jvm)" {
  val tmpDir = freshTempDir("cpgen-pair")
  val producerSrc = "package CpGenJvm.PairLib\n" + "\n" + "pub record Pair[A, B] { first: A; second: B }\n"
  val producerJar = buildJar(tmpDir, "CpGenJvm.PairLib", producerSrc, "CpGenJvm.PairLib")
  val consumerSrc = "package CpGenJvm.PairApp\n" + "\n" + "import CpGenJvm.PairLib\n" + "\n" + "func main(): Unit {\n" +
    "  val p = Pair(first = 7, second = \"seven\")\n" +
    "  println(p.first)\n" +
    "  println(p.second)\n" +
    "}\n"
  val captured = buildAndRunConsumer(
    tmpDir,
    "CpGenJvm.PairApp",
    consumerSrc,
    "CpGenJvm.PairApp",
    "CpGenJvm.PairLib",
    producerJar
  )
  cleanup(tmpDir)
  assertEqualInt(captured.exitCode, 0, "cpgen_pair_jvm: exit 0 (stderr=" + captured.stderr + ")")
  val lines = Str.split(Str.trim(captured.stdout), "\n")
  assertEqualInt(lines.count, 2, "cpgen_pair_jvm: two output lines")
  assertEqual(lines[0], "7", "cpgen_pair_jvm: first = 7")
  assertEqual(lines[1], "seven", "cpgen_pair_jvm: second = seven")
}

// Generic UNION: Maybe[Int] Just case - construct and match.
test "cross-package generic union Maybe[Int] Just matches (jvm)" {
  val tmpDir = freshTempDir("cpgen-maybe-just")
  val producerSrc = "package CpGenJvm.MaybeLib\n" + "\n" + "pub union Maybe[T] {\n" + "  case Just(value: T)\n" +
    "  case Nothing\n" +
    "}\n" +
    "\n" +
    "pub func getOrDefault(m: in Maybe[Int], d: in Int): Int {\n" +
    "  match m {\n" +
    "    case Just(v) -> v\n" +
    "    case Nothing -> d\n" +
    "  }\n" +
    "}\n"
  val producerJar = buildJar(tmpDir, "CpGenJvm.MaybeLib", producerSrc, "CpGenJvm.MaybeLib")
  val consumerSrc = "package CpGenJvm.MaybeApp\n" + "\n" + "import CpGenJvm.MaybeLib\n" + "\n" + "func main(): Unit {\n" +
    "  val m: Maybe[Int] = Just(value = 99)\n" +
    "  println(getOrDefault(m, 0))\n" +
    "}\n"
  val captured = buildAndRunConsumer(
    tmpDir,
    "CpGenJvm.MaybeApp",
    consumerSrc,
    "CpGenJvm.MaybeApp",
    "CpGenJvm.MaybeLib",
    producerJar
  )
  cleanup(tmpDir)
  assertEqualInt(captured.exitCode, 0, "cpgen_maybe_just_jvm: exit 0 (stderr=" + captured.stderr + ")")
  assertEqual(Str.trim(captured.stdout), "99", "cpgen_maybe_just_jvm: stdout = 99")
}

// Generic UNION: Maybe[Int] Nothing case - construct and match.
test "cross-package generic union Maybe[Int] Nothing matches (jvm)" {
  val tmpDir = freshTempDir("cpgen-maybe-nothing")
  val producerSrc = "package CpGenJvm.MaybeNothingLib\n" + "\n" + "pub union Maybe[T] {\n" + "  case Just(value: T)\n" +
    "  case Nothing\n" +
    "}\n" +
    "\n" +
    "pub func getOrDefault(m: in Maybe[Int], d: in Int): Int {\n" +
    "  match m {\n" +
    "    case Just(v) -> v\n" +
    "    case Nothing -> d\n" +
    "  }\n" +
    "}\n"
  val producerJar = buildJar(tmpDir, "CpGenJvm.MaybeNothingLib", producerSrc, "CpGenJvm.MaybeNothingLib")
  val consumerSrc = "package CpGenJvm.MaybeNothingApp\n" + "\n" + "import CpGenJvm.MaybeNothingLib\n" + "\n" +
    "func main(): Unit {\n" +
    "  val m: Maybe[Int] = Nothing\n" +
    "  println(getOrDefault(m, 77))\n" +
    "}\n"
  val captured = buildAndRunConsumer(
    tmpDir,
    "CpGenJvm.MaybeNothingApp",
    consumerSrc,
    "CpGenJvm.MaybeNothingApp",
    "CpGenJvm.MaybeNothingLib",
    producerJar
  )
  cleanup(tmpDir)
  assertEqualInt(captured.exitCode, 0, "cpgen_maybe_nothing_jvm: exit 0 (stderr=" + captured.stderr + ")")
  assertEqual(Str.trim(captured.stdout), "77", "cpgen_maybe_nothing_jvm: stdout = 77")
}

// Generic UNION: Maybe[String] Just with reference payload.
test "cross-package generic union Maybe[String] Just reference payload (jvm)" {
  val tmpDir = freshTempDir("cpgen-maybe-str")
  val producerSrc = "package CpGenJvm.MaybeStrLib\n" + "\n" + "pub union Maybe[T] {\n" + "  case Just(value: T)\n" +
    "  case Nothing\n" +
    "}\n"
  val producerJar = buildJar(tmpDir, "CpGenJvm.MaybeStrLib", producerSrc, "CpGenJvm.MaybeStrLib")
  val consumerSrc = "package CpGenJvm.MaybeStrApp\n" + "\n" + "import CpGenJvm.MaybeStrLib\n" + "\n" +
    "func main(): Unit {\n" +
    "  val m: Maybe[String] = Just(value = \"world\")\n" +
    "  val r = match m { case Just(s) -> s; case Nothing -> \"none\" }\n" +
    "  println(r)\n" +
    "}\n"
  val captured = buildAndRunConsumer(
    tmpDir,
    "CpGenJvm.MaybeStrApp",
    consumerSrc,
    "CpGenJvm.MaybeStrApp",
    "CpGenJvm.MaybeStrLib",
    producerJar
  )
  cleanup(tmpDir)
  assertEqualInt(captured.exitCode, 0, "cpgen_maybe_str_jvm: exit 0 (stderr=" + captured.stderr + ")")
  assertEqual(Str.trim(captured.stdout), "world", "cpgen_maybe_str_jvm: stdout = world")
}

// Regression test for #6668: a CONSUMER-declared function signature naming a
// restored, NON-generic type as both its parameter and return type — crossing
// a real call boundary (`main` calls `echoThing`, not just constructing or
// matching a restored type inline).  Every case above uses a GENERIC restored
// type (`Box[T]`/`Maybe[T]`), which erases to `Object` and never exercises
// this path: `Jvm.Bridge`'s `extPkgNames`/`extPkgMaps` owner registry
// (`collectFileDeclaredTypeFqns`) explicitly skips generic declarations, so a
// generic restored type's descriptor was never at risk of the wrong-owner bug
// this test targets. Before the #6668 fix, a restored artifact was never
// registered into `extPkgNames`/`extPkgMaps`, so `echoThing`'s descriptor
// resolved `Thing` via the "declared in my own package" fallback guess
// (`CpGenJvm.SigApp/Thing`, a class that is never compiled — `Thing` is only
// declared in the producer) instead of the real `CpGenJvm.SigLib/Thing`,
// producing a `NoClassDefFoundError` at class-load / first invocation.
test "cross-package non-generic restored type in a consumer function signature (jvm, #6668)" {
  val tmpDir = freshTempDir("cpgen-sig-owner")
  val producerSrc = "package CpGenJvm.SigLib\n" + "\n" + "pub record Thing { x: Int }\n" + "\n" +
    "pub func makeThing(v: in Int): Thing { Thing(x = v) }\n"
  val producerJar = buildJar(tmpDir, "CpGenJvm.SigLib", producerSrc, "CpGenJvm.SigLib")
  val consumerSrc = "package CpGenJvm.SigApp\n" + "\n" + "import CpGenJvm.SigLib\n" + "\n" +
    "func echoThing(t: in Thing): Thing {\n" +
    "  t\n" +
    "}\n" +
    "\n" +
    "func main(): Unit {\n" +
    "  val t = makeThing(5)\n" +
    "  val t2 = echoThing(t)\n" +
    "  println(t2.x)\n" +
    "}\n"
  val captured = buildAndRunConsumer(
    tmpDir,
    "CpGenJvm.SigApp",
    consumerSrc,
    "CpGenJvm.SigApp",
    "CpGenJvm.SigLib",
    producerJar
  )
  cleanup(tmpDir)
  assertEqualInt(captured.exitCode, 0, "cpgen_sig_owner_jvm: exit 0 (stderr=" + captured.stderr + ")")
  assertEqual(Str.trim(captured.stdout), "5", "cpgen_sig_owner_jvm: stdout = 5")
}
