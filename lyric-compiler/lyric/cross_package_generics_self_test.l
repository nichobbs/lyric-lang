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
// NOT covered here (confirmed a SEPARATE, pre-existing, non-restored-
// specific bug, out of #3273's restored-boundary scope): a closure bound to
// a `val` FIRST and passed BY NAME (`val g: () -> Result[Int, String] = {
// -> Ok(7) }; matchClosure(g)`) still panics identically — reproduced with
// zero restored-dependency plumbing at all (single in-bundle file, no
// import). The direct-argument detection this fix extends
// (`cctx.lambdaParamTypes`/`lambdaRetTypes`, #1939/#6511) only fires when
// `unwrapParenExpr(callArgExpr(...)).kind` is literally `ELambda` at the
// call site; a call argument that's an `EPath` reference to a previously-
// bound closure never reaches it, restored callee or not. Filed as #6877
// rather than folded in speculatively.
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
