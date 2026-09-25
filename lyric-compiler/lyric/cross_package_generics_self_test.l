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
//! Also covers the restored interface / record-method signature encoding
//! (docs/59 §3 F1): a cross-package `callvirt` whose signature mentions a
//! user record must encode the record concretely, not erased to `object`.
//!
//! Also covers CALLING a restored *generic function* (#6363, #6364, #6365):
//! a Lyric-level `[T]` function never gets a real cross-assembly MemberRef
//! in the compiled DLL (no MVAR generic-method support in either backend),
//! so the only way to call one from a restored consumer is for
//! `Lyric.Mono.monoFileWithImports` to specialise a concrete copy from its
//! ORIGINAL BODY.  Prior to this fix, `Lyric.ContractMeta.reprForFunc`
//! never carried a generic function's body into the contract metadata (only
//! `@inline_template` aspects carried a body), so a restored generic
//! function's re-synthesised declaration was always bodyless — invisible to
//! `pipeAddGenericFuncs`'s `hasBody` gate, so mono could never specialise a
//! call to it.  The un-specialised call then fell through to codegen's
//! unresolved cross-assembly-generic-function fallback and produced
//! unbalanced/degraded IL: a dropped call whose arguments leaked onto the
//! stack (`InvalidProgramException`), or a value silently reinterpreted as
//! the wrong type (`InvalidCastException`) — exactly what
//! `Std.Core.unwrapOr`/`isSome` and `Std.Collections.mapKeys`/`mapValues`
//! did when called against the restored, pre-compiled `Lyric.Stdlib.dll`.
//!
//! Also covers a SEPARATE, non-restored-specific bug in the same erasure
//! family (#6877): a closure bound to a `val`/`var` first and then passed
//! BY NAME to a higher-order call never propagated the binding's own
//! declared `() -> T` return type into the lifted lambda body, so a bare
//! union-case construction inside it erased an unconstrained type
//! parameter to `object`.  These tests are entirely in-bundle (no
//! restored package needed — see `buildAndRunSingle`).
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
  val paths: List[String] = newList()
  paths.add("")
  Emitter.ProjectPackage(name = name, sources = srcs, paths = paths)
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

// Build and run a single in-bundle package with NO restored dependency —
// used by the #6877 regression tests below, which reproduce entirely
// within one file (no cross-package plumbing needed).  Copies the compiled
// stdlib DLLs alongside the output (like `buildAndRunConsumerWithStdlib`
// above): a program that touches a stdlib generic case class (`Result`)
// resolves it against a real `Lyric.Stdlib` assembly reference, not an
// inlined copy.
func buildAndRunSingle(
  tmpDir: in String, pkgName: in String, source: in String, asmName: in String
): Capture.CaptureResult {
  val dllPath = buildDll(tmpDir, pkgName, source, asmName)
  Emitter.copyStdlibDllsBeside(dllPath, Emitter.findCompiledStdlibDir())
  writeRuntimeConfig(dllPath)
  val args: List[String] = newList()
  args.add("exec")
  args.add(dllPath)
  Capture.runCaptureWithDiagnostics("dotnet", args, "")
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
    nugetAssemblyPaths = newList(),
    defines = newList()
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

// Restored INTERFACE / record method with a record-typed signature (docs/59 §3
// F1): the consumer's MemberRef blob must encode a record param/return
// concretely (CLASS + TypeRef) to resolve against the producer's MethodDef,
// which is emitted ctx-aware (`buildInstanceMethodSigWithCtx`).  Before the
// fix `registerRestoredIfaceMethod` / `registerRestoredRecordMethod` encoded
// the blob with the erasing `buildInstanceMethodSig` (record -> object), so
// the callvirt failed at run time with MissingMethodException.  Covers both
// dispatch paths: a receiver typed as the INTERFACE (via `makeStore(): Store`)
// and a receiver typed as the CONCRETE RECORD (via `makeMemStore(): MemStore`).
test "cross-package restored interface method with record param and return" {
  val tmpDir = freshTempDir("cpgen-iface-rec")
  val producerSrc = "package CpGen.StoreLib\n" + "\n" + "pub record Entry { name: String; qty: Int }\n" + "\n" +
    "pub interface Store {\n" +
    "  func describe(e: in Entry): String\n" +
    "  func bump(e: in Entry): Entry\n" +
    "}\n" +
    "\n" +
    "pub record MemStore { prefix: String }\n" +
    "\n" +
    "impl Store for MemStore {\n" +
    "  func describe(e: in Entry): String { self.prefix + e.name + \":\" + toString(e.qty) }\n" +
    "  func bump(e: in Entry): Entry { Entry(name = e.name, qty = e.qty + 1) }\n" +
    "}\n" +
    "\n" +
    "pub func makeStore(): Store { MemStore(prefix = \"S/\") }\n" +
    "\n" +
    "pub func makeMemStore(): MemStore { MemStore(prefix = \"M/\") }\n"
  val producerDll = buildDll(tmpDir, "CpGen.StoreLib", producerSrc, "CpGen.StoreLib")
  val consumerSrc = "package CpGen.StoreApp\n" + "\n" + "import CpGen.StoreLib\n" + "\n" + "func main(): Unit {\n" +
    "  val s = makeStore()\n" +
    "  val e = Entry(name = \"apple\", qty = 2)\n" +
    "  println(s.describe(e))\n" +
    "  val e2 = s.bump(e)\n" +
    "  println(e2.qty)\n" +
    "  val m = makeMemStore()\n" +
    "  println(m.describe(e2))\n" +
    "}\n"
  val captured = buildAndRunConsumer(
    tmpDir,
    "CpGen.StoreApp",
    consumerSrc,
    "CpGen.StoreApp",
    "CpGen.StoreLib",
    producerDll
  )
  cleanup(tmpDir)
  assertEqualInt(captured.exitCode, 0, "cpgen_iface_rec: exit 0 (stderr=" + captured.stderr + ")")
  val lines = Str.split(Str.trim(captured.stdout), "\n")
  assertEqualInt(lines.count, 3, "cpgen_iface_rec: three output lines")
  assertEqual(lines[0], "S/apple:2", "cpgen_iface_rec: interface-dispatch describe(record)")
  assertEqual(lines[1], "3", "cpgen_iface_rec: record-returning bump(record) round-trips")
  assertEqual(lines[2], "M/apple:3", "cpgen_iface_rec: concrete-record-dispatch describe(record)")
}

// Calling a restored GENERIC FUNCTION whose result is composed directly
// into another restored generic function's argument (#6363's exact shape:
// `Std.Core.unwrapOr(Std.Char.hexDigitValue('a'), 0)` — nesting one
// restored-stdlib call's `Option[T]` result as the generic argument of
// another restored-stdlib generic function).  Before the fix, NEITHER
// `makeFull` nor `unwrapOrBox` had a body in the producer's contract
// metadata, so mono could not specialise either call site; the
// un-specialised calls degraded to unbalanced IL and crashed with
// `InvalidProgramException` at runtime.
test "cross-package generic function calls compose (#6363)" {
  val tmpDir = freshTempDir("cpgen-fn-compose")
  val producerSrc = "package CpGen.OptFuncLib\n" + "\n" + "pub union Box[T] {\n" + "  case Full(value: T)\n" +
    "  case Empty\n" +
    "}\n" +
    "\n" +
    "pub func makeFull[T](v: in T): Box[T] {\n" +
    "  Full(value = v)\n" +
    "}\n" +
    "\n" +
    "pub func unwrapOrBox[T](b: in Box[T], default: in T): T {\n" +
    "  match b {\n" +
    "    case Full(v) -> v\n" +
    "    case Empty -> default\n" +
    "  }\n" +
    "}\n"
  val producerDll = buildDll(tmpDir, "CpGen.OptFuncLib", producerSrc, "CpGen.OptFuncLib")
  val consumerSrc = "package CpGen.OptFuncApp\n" + "\n" + "import CpGen.OptFuncLib\n" + "\n" + "func main(): Unit {\n" +
    "  println(unwrapOrBox(makeFull(42), 0))\n" +
    "}\n"
  val captured = buildAndRunConsumer(
    tmpDir,
    "CpGen.OptFuncApp",
    consumerSrc,
    "CpGen.OptFuncApp",
    "CpGen.OptFuncLib",
    producerDll
  )
  cleanup(tmpDir)
  assertEqualInt(captured.exitCode, 0, "cpgen_fn_compose: exit 0 (stderr=" + captured.stderr + ")")
  assertEqual(Str.trim(captured.stdout), "42", "cpgen_fn_compose: unwrapOrBox(makeFull(42), 0) = 42")
}

// A restored generic PREDICATE function (mirrors `Std.Core.isSome`) called
// on a value whose type parameter is a record defined in the CONSUMER
// package — the record is unknown to the producer at the producer's own
// build time (#6365's shape: `Std.Core.isSome` called on an
// `Option[Widget]` where `Widget` is defined in a different consumer
// package than the one that produced the Option value).
test "cross-package generic predicate over a consumer-defined type (#6365)" {
  val tmpDir = freshTempDir("cpgen-fn-predicate")
  val producerSrc = "package CpGen.PredLib\n" + "\n" + "pub union Box[T] {\n" + "  case Full(value: T)\n" +
    "  case Empty\n" +
    "}\n" +
    "\n" +
    "pub func makeFull2[T](v: in T): Box[T] {\n" +
    "  Full(value = v)\n" +
    "}\n" +
    "\n" +
    "pub func isFullBox[T](b: in Box[T]): Bool {\n" +
    "  match b {\n" +
    "    case Full(v) -> true\n" +
    "    case Empty -> false\n" +
    "  }\n" +
    "}\n"
  val producerDll = buildDll(tmpDir, "CpGen.PredLib", producerSrc, "CpGen.PredLib")
  val consumerSrc = "package CpGen.PredApp\n" + "\n" + "import CpGen.PredLib\n" + "\n" +
    "record Widget { name: String }\n" +
    "\n" +
    "func main(): Unit {\n" +
    "  val full: Box[Widget] = makeFull2(Widget(name = \"gizmo\"))\n" +
    "  println(isFullBox(full).toString())\n" +
    "  val empty: Box[Widget] = Empty\n" +
    "  println(isFullBox(empty).toString())\n" +
    "}\n"
  val captured = buildAndRunConsumer(
    tmpDir,
    "CpGen.PredApp",
    consumerSrc,
    "CpGen.PredApp",
    "CpGen.PredLib",
    producerDll
  )
  cleanup(tmpDir)
  assertEqualInt(captured.exitCode, 0, "cpgen_fn_predicate: exit 0 (stderr=" + captured.stderr + ")")
  val lines = Str.split(Str.trim(captured.stdout), "\n")
  assertEqualInt(lines.count, 2, "cpgen_fn_predicate: two output lines")
  assertEqual(lines[0], "true", "cpgen_fn_predicate: isFullBox(Full(Widget)) = true")
  assertEqual(lines[1], "false", "cpgen_fn_predicate: isFullBox(Empty) = false")
}

// A restored generic function returning `List[V]` where `V` is a record
// defined in the CONSUMER package (#6364's shape: `Std.Collections.mapValues`
// on a `Map[String, Widget]` threw `InvalidCastException` casting the
// `Dictionary` itself to `IList` because the un-specialised call degraded
// to an identity pass-through instead of a real call).
test "cross-package generic function over List[consumer-defined type] (#6364)" {
  val tmpDir = freshTempDir("cpgen-fn-list")
  val producerSrc = "package CpGen.ListFuncLib\n" + "\n" + "import Std.Collections\n" + "\n" +
    "pub func firstOrDefault[T](xs: in List[T], default: in T): T {\n" +
    "  if xs.count > 0 {\n" +
    "    xs[0]\n" +
    "  } else {\n" +
    "    default\n" +
    "  }\n" +
    "}\n"
  val producerDll = buildDll(tmpDir, "CpGen.ListFuncLib", producerSrc, "CpGen.ListFuncLib")
  val consumerSrc = "package CpGen.ListFuncApp\n" + "\n" + "import Std.Collections\n" + "\n" +
    "import CpGen.ListFuncLib\n" +
    "\n" +
    "record Widget { name: String }\n" +
    "\n" +
    "func main(): Unit {\n" +
    "  val xs: List[Widget] = newList()\n" +
    "  xs.add(Widget(name = \"gizmo\"))\n" +
    "  val w = firstOrDefault(xs, Widget(name = \"none\"))\n" +
    "  println(w.name)\n" +
    "  val ys: List[Widget] = newList()\n" +
    "  val d = firstOrDefault(ys, Widget(name = \"fallback\"))\n" +
    "  println(d.name)\n" +
    "}\n"
  val captured = buildAndRunConsumer(
    tmpDir,
    "CpGen.ListFuncApp",
    consumerSrc,
    "CpGen.ListFuncApp",
    "CpGen.ListFuncLib",
    producerDll
  )
  cleanup(tmpDir)
  assertEqualInt(captured.exitCode, 0, "cpgen_fn_list: exit 0 (stderr=" + captured.stderr + ")")
  val lines = Str.split(Str.trim(captured.stdout), "\n")
  assertEqualInt(lines.count, 2, "cpgen_fn_list: two output lines")
  assertEqual(lines[0], "gizmo", "cpgen_fn_list: firstOrDefault(non-empty) = first element")
  assertEqual(lines[1], "fallback", "cpgen_fn_list: firstOrDefault(empty) = default")
}

// Like `buildAndRunConsumer` but also copies the compiled `Lyric.Stdlib.dll`
// beside the consumer output, so a consumer that constructs/matches a
// STDLIB generic union (`Result[T, E]`, `Option[T]`) directly — not merely a
// user-defined one — resolves its cross-assembly type references at run
// time. Every other test in this file exercises USER-defined generics (Box,
// Maybe) or a mono-specialised stdlib FUNCTION call (whose body is inlined,
// so it never touches the DLL at run time) — this is the first to construct
// a real stdlib generic case class across the restored boundary.
func buildAndRunConsumerWithStdlib(
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
    nugetAssemblyPaths = newList(),
    defines = newList()
  )
  val result = Emitter.emitProject(req)
  match result.outputPath {
    case None -> panic("buildAndRunConsumerWithStdlib(" + consumerAsmName + "): compilation failed")
    case Some(_) -> ()
  }
  Emitter.copyStdlibDllsBeside(dllPath, Emitter.findCompiledStdlibDir())
  writeRuntimeConfig(dllPath)
  val args: List[String] = newList()
  args.add("exec")
  args.add(dllPath)
  Capture.runCaptureWithDiagnostics("dotnet", args, "")
}

// #3273 item 4: a consumer closure LITERAL passed DIRECTLY as a call
// argument, invoked and matched INSIDE a restored library, must construct
// the stdlib `Result[T, E]` union case with BOTH type parameters pinned
// correctly, not just the one an argument happens to cover.
// `matchClosure`'s function-typed parameter is restored (cross-assembly),
// so the lambda literal `{ -> Ok(42) }` passed directly at the call site
// has no in-bundle `addPackageTokens` registration to inherit its declared
// `() -> Result[Int, String]` return type from — before the fix,
// `registerRestoredFunc` never populated
// `funcParamFnInner`/`funcParamFnRetType` for a restored function's
// function-typed parameters (only `addPackageTokens`, for in-bundle ones,
// did), so the lifted lambda body fell back to the Uniform Func ABI's
// `declaredRetTy = Object`: `Ok(42)` built a `Result_Ok<Int, Object>` (the
// `E` slot, unreachable from the `Ok` payload alone, erased) instead of
// `Result_Ok<Int, String>` — an `InvalidCastException` unpacking the boxed
// return at the restored `matchClosure`'s `f()` call site. `Err(...)` is
// unaffected by this precise erasure (its own payload pins `E` directly)
// but was exercised too for symmetry.
//
// A SEPARATE, pre-existing, non-restored-specific bug (out of #3273's
// restored-boundary scope, filed as #6877 and fixed by
// `registerLocalLambdaLiteralFnTypesMsil`): a closure bound to a `val`
// FIRST and passed BY NAME (`val g: () -> Result[Int, String] = { -> Ok(7)
// }; matchClosure(g)`) panicked identically — reproducible with zero
// restored-dependency plumbing at all (single in-bundle file, no import).
// The direct-argument detection above (`cctx.lambdaParamTypes`/
// `lambdaRetTypes`, #1939/#6511) only fires when
// `unwrapParenExpr(callArgExpr(...)).kind` is literally `ELambda` at the
// call site; a call argument that's an `EPath` reference to a previously-
// bound closure never reaches it, restored callee or not. Covered by the
// `cpgen_val_bound_closure_*` tests below (in-bundle, no restored package
// needed — the bug lives entirely in the LOCAL BINDING's own lowering).
test "cross-package Result identity: consumer closure literal passed to a restored function's function-typed parameter (#3273)" {
  val tmpDir = freshTempDir("cpgen-result-closure")
  val producerSrc = "package CpGen.ResultLib\n" + "\n" + "pub func matchClosure(f: () -> Result[Int, String]): Int {\n" +
    "  match f() {\n" +
    "    case Ok(v) -> v\n" +
    "    case Err(_) -> -1\n" +
    "  }\n" +
    "}\n"
  val producerDll = buildDll(tmpDir, "CpGen.ResultLib", producerSrc, "CpGen.ResultLib")
  val consumerSrc = "package CpGen.ResultApp\n" + "\n" + "import CpGen.ResultLib\n" + "\n" + "func main(): Unit {\n" +
    "  println(matchClosure({ -> Ok(42) }))\n" +
    "  println(matchClosure({ -> Err(\"boom\") }))\n" +
    "}\n"
  val captured = buildAndRunConsumerWithStdlib(
    tmpDir,
    "CpGen.ResultApp",
    consumerSrc,
    "CpGen.ResultApp",
    "CpGen.ResultLib",
    producerDll
  )
  cleanup(tmpDir)
  assertEqualInt(captured.exitCode, 0, "cpgen_result_closure: exit 0 (stderr=" + captured.stderr + ")")
  val lines = Str.split(Str.trim(captured.stdout), "\n")
  assertEqualInt(lines.count, 2, "cpgen_result_closure: two output lines")
  assertEqual(lines[0], "42", "cpgen_result_closure: direct Ok(42) literal dispatches to the Ok arm")
  assertEqual(lines[1], "-1", "cpgen_result_closure: direct Err(\"boom\") literal dispatches to the Err arm")
}

// #6877: the exact repro from the issue — a closure bound to a `val` FIRST
// (with its own `() -> Result[Int, String]` annotation), then passed BY
// NAME to a higher-order call. Entirely in-bundle, no restored package:
// the bug lives in `LBVal`'s own lowering never seeding
// `cctx.lambdaParamTypes`/`lambdaRetTypes` before the lambda-literal
// initializer is lowered, so the lifted lambda body fell back to the
// Uniform Func ABI's `declaredRetTy = Object` and `Ok(v)` erased `E` to
// `object` — an `InvalidCastException` unpacking `f()`'s boxed return.
test "in-bundle val-bound closure passed by name preserves Result's type params (#6877)" {
  val tmpDir = freshTempDir("cpgen-valbound-result")
  val src = "package Repro.ValBoundResult\n" + "\n" + "func matchClosure(f: () -> Result[Int, String]): Int {\n" +
    "  match f() {\n" +
    "    case Ok(v) -> v\n" +
    "    case Err(_) -> -1\n" +
    "  }\n" +
    "}\n" +
    "\n" +
    "func main(): Unit {\n" +
    "  val g: () -> Result[Int, String] = { -> Ok(7) }\n" +
    "  println(matchClosure(g))\n" +
    "  val h: () -> Result[Int, String] = { -> Err(\"boom\") }\n" +
    "  println(matchClosure(h))\n" +
    "}\n"
  val captured = buildAndRunSingle(tmpDir, "Repro.ValBoundResult", src, "Repro.ValBoundResult")
  cleanup(tmpDir)
  assertEqualInt(captured.exitCode, 0, "cpgen_valbound_result: exit 0 (stderr=" + captured.stderr + ")")
  val lines = Str.split(Str.trim(captured.stdout), "\n")
  assertEqualInt(lines.count, 2, "cpgen_valbound_result: two output lines")
  assertEqual(lines[0], "7", "cpgen_valbound_result: val-bound Ok(7) dispatches to the Ok arm")
  assertEqual(lines[1], "-1", "cpgen_valbound_result: val-bound Err(\"boom\") dispatches to the Err arm")
}

// #6877 variant: a PARAMETERIZED val-bound closure (exercises
// `lambdaParamTypes`, not just `lambdaRetTypes`) against a user-DEFINED
// generic union (not the stdlib `Result`), to confirm the fix isn't
// scoped to `Std.Core.Result` specifically.
test "in-bundle val-bound parameterized closure preserves a user-defined generic union's type params (#6877)" {
  val tmpDir = freshTempDir("cpgen-valbound-union")
  val src = "package Repro.ValBoundUnion\n" + "\n" + "union Verdict[T, E] {\n" + "  case Good(value: T)\n" +
    "  case Bad(err: E)\n" +
    "}\n" +
    "\n" +
    "func matchVerdict(f: (Int) -> Verdict[Int, String]): Int {\n" +
    "  match f(3) {\n" +
    "    case Good(v) -> v\n" +
    "    case Bad(_) -> -1\n" +
    "  }\n" +
    "}\n" +
    "\n" +
    "func main(): Unit {\n" +
    "  val g: (Int) -> Verdict[Int, String] = { x -> Good(value = x + 10) }\n" +
    "  println(matchVerdict(g))\n" +
    "}\n"
  val captured = buildAndRunSingle(tmpDir, "Repro.ValBoundUnion", src, "Repro.ValBoundUnion")
  cleanup(tmpDir)
  assertEqualInt(captured.exitCode, 0, "cpgen_valbound_union: exit 0 (stderr=" + captured.stderr + ")")
  assertEqual(Str.trim(captured.stdout), "13", "cpgen_valbound_union: val-bound Good(13) dispatches to the Good arm")
}

// #6877 variant: `var`-bound (not `val`) closure passed by name — the fix
// is applied to `LBVar`'s lowering too, not only `LBVal`'s.
test "in-bundle var-bound closure passed by name preserves Result's type params (#6877)" {
  val tmpDir = freshTempDir("cpgen-varbound-result")
  val src = "package Repro.VarBoundResult\n" + "\n" + "func matchClosure(f: () -> Result[Int, String]): Int {\n" +
    "  match f() {\n" +
    "    case Ok(v) -> v\n" +
    "    case Err(_) -> -1\n" +
    "  }\n" +
    "}\n" +
    "\n" +
    "func main(): Unit {\n" +
    "  var g: () -> Result[Int, String] = { -> Ok(21) }\n" +
    "  println(matchClosure(g))\n" +
    "}\n"
  val captured = buildAndRunSingle(tmpDir, "Repro.VarBoundResult", src, "Repro.VarBoundResult")
  cleanup(tmpDir)
  assertEqualInt(captured.exitCode, 0, "cpgen_varbound_result: exit 0 (stderr=" + captured.stderr + ")")
  assertEqual(Str.trim(captured.stdout), "21", "cpgen_varbound_result: var-bound Ok(21) dispatches to the Ok arm")
}

// A producer assembly holding several packages.
func buildDllPkgs(tmpDir: in String, pkgs: in List[Emitter.ProjectPackage], asmName: in String): String {
  val dllPath = Path.join(tmpDir, asmName + ".dll")
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
  match Emitter.emitProject(req).outputPath {
    case None -> panic("buildDllPkgs(" + asmName + "): compilation failed")
    case Some(_) -> ()
  }
  dllPath
}

// A restored generic whose body calls a SIBLING package's function through
// its package name (`CpSess.Session.start(m)`, inside a closure) specialises
// in the consumer (D-progress-965).  The stored body is alias-rewritten
// source; re-parsed, the qualified call is a member chain and codegen read
// `CpSess.Session` as a value (T0115) until the package's recorded imports
// were brought back into scope.
test "cross-package generic calling a sibling package by name inside a closure (D-progress-965)" {
  val tmpDir = freshTempDir("cpgen-sibling-qualified")
  val sessionSrc = "package CpSess.Session\n" + "\n" + "pub record Session[M] {\n" + "  model: M\n" + "}\n" + "\n" +
    "pub record Output[M] {\n" +
    "  session: Session[M]\n" +
    "  count: Int\n" +
    "}\n" +
    "\n" +
    "pub func start[M](m: in M): Output[M] {\n" +
    "  return Output(session = Session(model = m), count = 1)\n" +
    "}\n"
  val hostSrc = "package CpSess.Host\n" + "\n" + "import CpSess.Session\n" + "import CpSess.Session.{Session, Output}\n" +
    "\n" +
    "pub record Instance {\n" +
    "  run: () -> Int\n" +
    "}\n" +
    "\n" +
    "pub func instance[M](m: in M): Instance {\n" +
    "  return Instance(run = { ->\n" +
    "    val o: Output[M] = Session.start(m)\n" +
    "    val s: Session[M] = o.session\n" +
    "    o.count\n" +
    "  })\n" +
    "}\n"
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(mkPkg("CpSess.Session", sessionSrc))
  pkgs.add(mkPkg("CpSess.Host", hostSrc))
  val producerDll = buildDllPkgs(tmpDir, pkgs, "CpSess.Lib")
  val consumerSrc = "package CpSess.App\n" + "\n" + "import CpSess.Host.{instance}\n" + "\n" + "func main(): Unit {\n" +
    "  val i = instance(5)\n" +
    "  println(i.run())\n" +
    "}\n"
  val dllPath = Path.join(tmpDir, "CpSess.App.dll")
  val cpkgs: List[Emitter.ProjectPackage] = newList()
  cpkgs.add(mkPkg("CpSess.App", consumerSrc))
  val restored: List[String] = newList()
  restored.add("CpSess.Session\t" + producerDll)
  restored.add("CpSess.Host\t" + producerDll)
  val req = Emitter.EmitProjectRequest(
    packages = cpkgs,
    assemblyName = "CpSess.App",
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
  match Emitter.emitProject(req).outputPath {
    case None -> panic("cpgen_sibling_qualified: consumer compilation failed")
    case Some(_) -> ()
  }
  writeRuntimeConfig(dllPath)
  val args: List[String] = newList()
  args.add("exec")
  args.add(dllPath)
  val captured = Capture.runCaptureWithDiagnostics("dotnet", args, "")
  cleanup(tmpDir)
  assertEqualInt(captured.exitCode, 0, "cpgen_sibling_qualified: exit 0 (stderr=" + captured.stderr + ")")
  assertEqual(Str.trim(captured.stdout), "1", "cpgen_sibling_qualified: output")
}

// Qualified calls into a restored package (D-progress-968): an `Int` literal
// passed to a `Long` parameter is widened, and a generic whose type parameter
// is fixed only by another restored call's `Result[Long, String]` specialises
// at `Long` rather than at the `Int` of its literal fallback.
test "qualified restored calls widen Int arguments and type generics from their results (D-progress-968)" {
  val tmpDir = freshTempDir("cplong-qualified")
  val producerSrc = "package CpLong.Parse\n" + "\n" + "pub func span(lo: in Long, hi: in Long): Long { hi - lo }\n" +
    "\n" +
    "pub func longOr(raw: in String): Result[Long, String] {\n" +
    "  if raw == \"big\" { Ok(value = 5000000000i64) } else { Err(error = \"bad\") }\n" +
    "}\n" +
    "\n" +
    "pub func collect[T](errs: in List[String], r: in Result[T, String], fallback: in T): T {\n" +
    "  match r {\n" +
    "    case Ok(v) -> v\n" +
    "    case Err(e) -> {\n" +
    "      errs.add(e)\n" +
    "      fallback\n" +
    "    }\n" +
    "  }\n" +
    "}\n"
  val producerDll = buildDll(tmpDir, "CpLong.Parse", producerSrc, "CpLong.Parse")
  val consumerSrc = "package CpLong.App\n" + "\n" + "import CpLong.Parse\n" + "\n" + "func main(): Unit {\n" +
    "  val errs: List[String] = newList()\n" +
    "  val big = Parse.collect(errs, Parse.longOr(\"big\"), 0)\n" +
    "  val dflt = Parse.collect(errs, Parse.longOr(\"x\"), 7)\n" +
    "  println(Parse.span(-5, 1_000_000).toString() + \" \" + big.toString() + \" \" + dflt.toString() + \" \" + errs.length.toString())\n" +
    "}\n"
  val captured = buildAndRunConsumerWithStdlib(
    tmpDir,
    "CpLong.App",
    consumerSrc,
    "CpLong.App",
    "CpLong.Parse",
    producerDll
  )
  cleanup(tmpDir)
  assertEqualInt(captured.exitCode, 0, "cplong_qualified: exit 0 (stderr=" + captured.stderr + ")")
  assertEqual(Str.trim(captured.stdout), "1000005 5000000000 7 1", "cplong_qualified: widened span and Long collect")
}

// A generic from one restored package binds an annotated local from calls to
// another package's generics that take a lambda local, then passes it on
// (`field(..., input)`): the local keeps its annotated `View[Msg]`, so the
// inner generic specialises at `Msg`, not `Object` (D-progress-968).
test "an annotated local in a specialised generic keeps its type across packages (D-progress-968)" {
  val tmpDir = freshTempDir("cpgen-annotated-local")
  val coreSrc = "package CpView.Core\n" + "\n" + "pub union View[Msg] {\n" +
    "  case Wrap(label: String, inner: View[Msg])\n" +
    "  case Click(msg: Msg)\n" +
    "}\n"
  val widgetsSrc = "package CpView.Widgets\n" + "\n" + "import CpView.Core.{View, Wrap, Click}\n" + "\n" +
    "pub func field[Msg](label: in String, errors: in List[String], inner: in View[Msg]): View[Msg] {\n" +
    "  Wrap(label = label, inner = inner)\n" +
    "}\n" +
    "\n" +
    "pub func textInput[Msg](v: in String, f: in (String) -> Msg): View[Msg] { Click(msg = f(v)) }\n"
  val formsSrc = "package CpView.Forms\n" + "\n" + "import CpView.Core.{View}\n" +
    "import CpView.Widgets.{field, textInput}\n" +
    "\n" +
    "pub func fieldView[Msg](flag: in Bool, v: in String, onEdit: in (String, String) -> Msg): View[Msg] {\n" +
    "  val name = \"n\"\n" +
    "  val onInput = { s: String -> onEdit(name, s) }\n" +
    "  val input: View[Msg] = if flag { textInput(v, onInput) } else { textInput(v + \"!\", onInput) }\n" +
    "  val msgs: List[String] = newList()\n" +
    "  return field(\"lbl\", msgs, input)\n" +
    "}\n"
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(mkPkg("CpView.Core", coreSrc))
  pkgs.add(mkPkg("CpView.Widgets", widgetsSrc))
  pkgs.add(mkPkg("CpView.Forms", formsSrc))
  val producerDll = buildDllPkgs(tmpDir, pkgs, "CpView.Lib")
  val consumerSrc = "package CpView.App\n" + "\n" + "import CpView.Core.{View, Wrap, Click}\n" +
    "import CpView.Forms.{fieldView}\n" +
    "\n" +
    "union Msg {\n" +
    "  case Edited(n: String, s: String)\n" +
    "}\n" +
    "\n" +
    "func main(): Unit {\n" +
    "  match fieldView(true, \"x\", { n: String, s: String -> Edited(n = n, s = s) }) {\n" +
    "    case Wrap(l, Click(Edited(n, s))) -> println(l + \" \" + n + \" \" + s)\n" +
    "    case _ -> println(\"other\")\n" +
    "  }\n" +
    "}\n"
  val dllPath = Path.join(tmpDir, "CpView.App.dll")
  val cpkgs: List[Emitter.ProjectPackage] = newList()
  cpkgs.add(mkPkg("CpView.App", consumerSrc))
  val restored: List[String] = newList()
  restored.add("CpView.Core\t" + producerDll)
  restored.add("CpView.Widgets\t" + producerDll)
  restored.add("CpView.Forms\t" + producerDll)
  val req = Emitter.EmitProjectRequest(
    packages = cpkgs,
    assemblyName = "CpView.App",
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
  match Emitter.emitProject(req).outputPath {
    case None -> panic("cpgen_annotated_local: consumer compilation failed")
    case Some(_) -> ()
  }
  Emitter.copyStdlibDllsBeside(dllPath, Emitter.findCompiledStdlibDir())
  writeRuntimeConfig(dllPath)
  val args: List[String] = newList()
  args.add("exec")
  args.add(dllPath)
  val captured = Capture.runCaptureWithDiagnostics("dotnet", args, "")
  cleanup(tmpDir)
  assertEqualInt(captured.exitCode, 0, "cpgen_annotated_local: exit 0 (stderr=" + captured.stderr + ")")
  assertEqual(Str.trim(captured.stdout), "lbl n x", "cpgen_annotated_local: inner generic specialised at Msg")
}

// A range subtype restored from a dependency stringifies as its underlying
// value, like an in-bundle one (D-progress-967).
test "a restored range subtype renders as its value (D-progress-967)" {
  val tmpDir = freshTempDir("cprange-restored")
  val producerSrc = "package CpRange.Money\n" + "\n" + "pub type Cents = Long range 0 ..= 1000000\n" + "\n" +
    "pub func cents(n: in Long): Cents { Cents.from(n) }\n"
  val producerDll = buildDll(tmpDir, "CpRange.Money", producerSrc, "CpRange.Money")
  val consumerSrc = "package CpRange.App\n" + "\n" + "import CpRange.Money\n" + "import CpRange.Money.{Cents}\n" + "\n" +
    "func show(c: in Cents): String { c.toString() + \" \${c} \" + toString(c) }\n" +
    "\n" +
    "func main(): Unit {\n" +
    "  println(show(Money.cents(5000)))\n" +
    "}\n"
  val captured = buildAndRunConsumerWithStdlib(
    tmpDir,
    "CpRange.App",
    consumerSrc,
    "CpRange.App",
    "CpRange.Money",
    producerDll
  )
  cleanup(tmpDir)
  assertEqualInt(captured.exitCode, 0, "cprange_restored: exit 0 (stderr=" + captured.stderr + ")")
  assertEqual(Str.trim(captured.stdout), "5000 5000 5000", "cprange_restored: restored range renders by value")
}
