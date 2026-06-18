//! cross_package_generics_self_test.l — regression tests for user-defined generic
//! records and unions consumed from a restored (pre-compiled) package (#1496).
//!
//! Prior to this fix the self-hosted MSIL codegen registered cross-package generic
//! types with plain (non-arity-suffixed) TypeRef names and without the generic
//! metadata maps that construction and field-read dispatch require.  As a result:
//!   - `Box[Int]` construction fell back to a plain MemberRef whose sig mismatched
//!     the DLL's VAR-form `.ctor`, causing "Method not found" at runtime.
//!   - `b.value` on a `Box[Int]` receiver fell through to `pop + MObject` because
//!     fieldSigBytes was not populated, returning 0 instead of the stored value.
//!   - `match m { case Just(v) -> v; case Nothing -> 0 }` silently matched the
//!     wrong arm because the isinst TypeSpec referenced the wrong TypeDef name.
//!
//! Each test here builds a PRODUCER DLL (generic record / union) in-process via
//! `Lyric.Emitter.emitProject`, then builds a CONSUMER that imports the producer
//! as a restored dep, runs it, and asserts the printed output.
//!
//! Run via native `lyric test` with LYRIC_LOAD_COMPILER=1 (required because
//! the test imports `Lyric.Emitter`, a compiler package):
//!   LYRIC_LOAD_COMPILER=1 lyric test lyric-compiler/lyric/cross_package_generics_self_test.l
//!
@test_module
package Lyric.CrossPackageGenericsSelfTest

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
  val root = Path.join(tempBase(), "lyric-cpgen-" + label + "-" + uuidToString(newUuid()))
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
    buildKind = "lib"
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
    buildKind = "lib"
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
// Generic RECORD: construct Box[Int] from a restored package, read .value.
test "cross-package generic record Box[Int] construct and read" {
  val tmpDir = freshTempDir("cpgen-box-int")
  val producerSrc = "package CpGen.Lib\n" + "\n" + "pub record Box[T] { value: T }\n" + "\n" +
    "pub func unboxInt(b: in Box[Int]): Int { b.value }\n"
  val producerDll = buildDll(tmpDir, "CpGen.Lib", producerSrc, "CpGen.Lib")
  val consumerSrc = "package CpGen.App\n" + "\n" + "import CpGen.Lib\n" + "\n" + "func main(): Unit {\n" +
    "  val b = Box(value = 42)\n" +
    "  println(unboxInt(b))\n" +
    "}\n"
  val captured = buildAndRunConsumer(tmpDir, "CpGen.App", consumerSrc, "CpGen.App", "CpGen.Lib", producerDll)
  cleanup(tmpDir)
  assertEqualInt(captured.exitCode, 0, "cpgen_box_int: exit 0 (stderr=" + captured.stderr + ")")
  assertEqual(Str.trim(captured.stdout), "42", "cpgen_box_int: stdout = 42")
}

// Generic RECORD: Box[String] with a reference-typed field.
test "cross-package generic record Box[String] construct and read" {
  val tmpDir = freshTempDir("cpgen-box-str")
  val producerSrc = "package CpGen.BoxStr\n" + "\n" + "pub record Box[T] { value: T }\n"
  val producerDll = buildDll(tmpDir, "CpGen.BoxStr", producerSrc, "CpGen.BoxStr")
  val consumerSrc = "package CpGen.BoxStrApp\n" + "\n" + "import CpGen.BoxStr\n" + "\n" + "func main(): Unit {\n" +
    "  val b = Box(value = \"hello\")\n" +
    "  println(b.value)\n" +
    "}\n"
  val captured = buildAndRunConsumer(
    tmpDir,
    "CpGen.BoxStrApp",
    consumerSrc,
    "CpGen.BoxStrApp",
    "CpGen.BoxStr",
    producerDll
  )
  cleanup(tmpDir)
  assertEqualInt(captured.exitCode, 0, "cpgen_box_str: exit 0 (stderr=" + captured.stderr + ")")
  assertEqual(Str.trim(captured.stdout), "hello", "cpgen_box_str: stdout = hello")
}

// Generic RECORD: Pair[Int, String] two type parameters.
test "cross-package generic record Pair[Int,String] both fields" {
  val tmpDir = freshTempDir("cpgen-pair")
  val producerSrc = "package CpGen.PairLib\n" + "\n" + "pub record Pair[A, B] { first: A; second: B }\n"
  val producerDll = buildDll(tmpDir, "CpGen.PairLib", producerSrc, "CpGen.PairLib")
  val consumerSrc = "package CpGen.PairApp\n" + "\n" + "import CpGen.PairLib\n" + "\n" + "func main(): Unit {\n" +
    "  val p = Pair(first = 7, second = \"seven\")\n" +
    "  println(p.first)\n" +
    "  println(p.second)\n" +
    "}\n"
  val captured = buildAndRunConsumer(
    tmpDir,
    "CpGen.PairApp",
    consumerSrc,
    "CpGen.PairApp",
    "CpGen.PairLib",
    producerDll
  )
  cleanup(tmpDir)
  assertEqualInt(captured.exitCode, 0, "cpgen_pair: exit 0 (stderr=" + captured.stderr + ")")
  val lines = Str.split(Str.trim(captured.stdout), "\n")
  assertEqualInt(lines.count, 2, "cpgen_pair: two output lines")
  assertEqual(lines[0], "7", "cpgen_pair: first = 7")
  assertEqual(lines[1], "seven", "cpgen_pair: second = seven")
}

// Generic UNION: Maybe[Int] Just case - construct and match.
test "cross-package generic union Maybe[Int] Just matches" {
  val tmpDir = freshTempDir("cpgen-maybe-just")
  val producerSrc = "package CpGen.MaybeLib\n" + "\n" + "pub union Maybe[T] {\n" + "  case Just(value: T)\n" +
    "  case Nothing\n" +
    "}\n" +
    "\n" +
    "pub func getOrDefault(m: in Maybe[Int], d: in Int): Int {\n" +
    "  match m {\n" +
    "    case Just(v) -> v\n" +
    "    case Nothing -> d\n" +
    "  }\n" +
    "}\n"
  val producerDll = buildDll(tmpDir, "CpGen.MaybeLib", producerSrc, "CpGen.MaybeLib")
  val consumerSrc = "package CpGen.MaybeApp\n" + "\n" + "import CpGen.MaybeLib\n" + "\n" + "func main(): Unit {\n" +
    "  val m: Maybe[Int] = Just(value = 99)\n" +
    "  println(getOrDefault(m, 0))\n" +
    "}\n"
  val captured = buildAndRunConsumer(
    tmpDir,
    "CpGen.MaybeApp",
    consumerSrc,
    "CpGen.MaybeApp",
    "CpGen.MaybeLib",
    producerDll
  )
  cleanup(tmpDir)
  assertEqualInt(captured.exitCode, 0, "cpgen_maybe_just: exit 0 (stderr=" + captured.stderr + ")")
  assertEqual(Str.trim(captured.stdout), "99", "cpgen_maybe_just: stdout = 99")
}

// Generic UNION: Maybe[Int] Nothing case - construct and match.
test "cross-package generic union Maybe[Int] Nothing matches" {
  val tmpDir = freshTempDir("cpgen-maybe-nothing")
  val producerSrc = "package CpGen.MaybeNothingLib\n" + "\n" + "pub union Maybe[T] {\n" + "  case Just(value: T)\n" +
    "  case Nothing\n" +
    "}\n" +
    "\n" +
    "pub func getOrDefault(m: in Maybe[Int], d: in Int): Int {\n" +
    "  match m {\n" +
    "    case Just(v) -> v\n" +
    "    case Nothing -> d\n" +
    "  }\n" +
    "}\n"
  val producerDll = buildDll(tmpDir, "CpGen.MaybeNothingLib", producerSrc, "CpGen.MaybeNothingLib")
  val consumerSrc = "package CpGen.MaybeNothingApp\n" + "\n" + "import CpGen.MaybeNothingLib\n" + "\n" +
    "func main(): Unit {\n" +
    "  val m: Maybe[Int] = Nothing\n" +
    "  println(getOrDefault(m, 77))\n" +
    "}\n"
  val captured = buildAndRunConsumer(
    tmpDir,
    "CpGen.MaybeNothingApp",
    consumerSrc,
    "CpGen.MaybeNothingApp",
    "CpGen.MaybeNothingLib",
    producerDll
  )
  cleanup(tmpDir)
  assertEqualInt(captured.exitCode, 0, "cpgen_maybe_nothing: exit 0 (stderr=" + captured.stderr + ")")
  assertEqual(Str.trim(captured.stdout), "77", "cpgen_maybe_nothing: stdout = 77")
}

// Generic UNION: Maybe[String] Just with reference payload.
test "cross-package generic union Maybe[String] Just reference payload" {
  val tmpDir = freshTempDir("cpgen-maybe-str")
  val producerSrc = "package CpGen.MaybeStrLib\n" + "\n" + "pub union Maybe[T] {\n" + "  case Just(value: T)\n" +
    "  case Nothing\n" +
    "}\n"
  val producerDll = buildDll(tmpDir, "CpGen.MaybeStrLib", producerSrc, "CpGen.MaybeStrLib")
  val consumerSrc = "package CpGen.MaybeStrApp\n" + "\n" + "import CpGen.MaybeStrLib\n" + "\n" + "func main(): Unit {\n" +
    "  val m: Maybe[String] = Just(value = \"world\")\n" +
    "  val r = match m { case Just(s) -> s; case Nothing -> \"none\" }\n" +
    "  println(r)\n" +
    "}\n"
  val captured = buildAndRunConsumer(
    tmpDir,
    "CpGen.MaybeStrApp",
    consumerSrc,
    "CpGen.MaybeStrApp",
    "CpGen.MaybeStrLib",
    producerDll
  )
  cleanup(tmpDir)
  assertEqualInt(captured.exitCode, 0, "cpgen_maybe_str: exit 0 (stderr=" + captured.stderr + ")")
  assertEqual(Str.trim(captured.stdout), "world", "cpgen_maybe_str: stdout = world")
}
