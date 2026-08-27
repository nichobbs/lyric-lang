//! restored_slice_list_return_self_test.l — regression test for #5575's
//! residual finding: a restored-dependency function returning
//! `List[slice[Byte]]` threw `InvalidCastException: Unable to cast object
//! of type 'System.Collections.Generic.List`1[System.Object]' to type
//! 'System.Collections.Generic.List`1[System.Byte[]]'` at the call site —
//! the `List<Object>` vs `List<byte[]>` erasure mismatch from a
//! restored-dependency return-type array signature (the `collectBytes`
//! shape named in #5575's triage comment).
//!
//! Already fixed by PR #6329's #6332 extension (`bufMsilTypeSigSlot`
//! degrading an `MArray`-typed field/param/return signature slot to
//! `Object` when the element type has no genuine CLR array token) — that
//! PR's own regression coverage (`slice_array_abi_self_test.l`) is
//! same-bundle only; this test pins the identical fix across a genuine
//! restored-DLL boundary, the shape #5575 is actually about.
//!
//! Builds a PRODUCER DLL exposing `collectBytes(): List[slice[Byte]]` in-
//! process via `Lyric.Emitter.emitProject`, then a CONSUMER that calls it
//! as a restored dep and reads the returned list — the same two-stage
//! harness as `restored_async_self_test.l`.
//!
//! Run via native `lyric test` with LYRIC_LOAD_COMPILER=1 (required because
//! the test imports `Lyric.Emitter`, a compiler package):
//!   LYRIC_LOAD_COMPILER=1 lyric test lyric-compiler/lyric/restored_slice_list_return_self_test.l
@test_module
package Lyric.RestoredSliceListReturnSelfTest

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

func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", Environment.getVarOrDefault("TEMP", Environment.getVarOrDefault("TMP", "/tmp")))
}

func freshTempDir(label: in String): String {
  val root = Path.join(tempBase(), "lyric-slicelist-" + label + "-" + uuidToString(newUuid()))
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

func producerSource(pkg: in String): String {
  "package " + pkg + "\n" + "\n" + "pub func collectBytes(): List[slice[Byte]] {\n" +
    "  val result: List[slice[Byte]] = newList()\n" +
    "  val a: List[Byte] = newList()\n" +
    "  a.add(1)\n" +
    "  a.add(2)\n" +
    "  result.add(a.toArray())\n" +
    "  val b: List[Byte] = newList()\n" +
    "  b.add(3)\n" +
    "  result.add(b.toArray())\n" +
    "  result\n" +
    "}\n"
}

// #5575: a restored-dependency function returning List[slice[Byte]] must
// not throw InvalidCastException at the call site.
test "restored dependency function returning List[slice[Byte]] round-trips correctly (#5575)" {
  val tmpDir = freshTempDir("collectbytes")
  val producerDll = buildDll(tmpDir, "SliceList.Lib", producerSource("SliceList.Lib"), "SliceList.Lib")
  val consumerSrc = "package SliceList.App\n" + "\n" + "import SliceList.Lib\n" + "\n" + "func main(): Unit {\n" +
    "  val items = collectBytes()\n" +
    "  println(items.count)\n" +
    "  var i = 0\n" +
    "  while i < items.count {\n" +
    "    println(items[i].length)\n" +
    "    i += 1\n" +
    "  }\n" +
    "}\n"
  val captured = buildAndRunConsumer(
    tmpDir,
    "SliceList.App",
    consumerSrc,
    "SliceList.App",
    "SliceList.Lib",
    producerDll
  )
  cleanup(tmpDir)
  assertEqualInt(captured.exitCode, 0, "collectbytes: exit 0 (stderr=" + captured.stderr + ")")
  assertEqual(
    Str.trim(captured.stdout),
    "2\n2\n1",
    "collectbytes: two byte slices of length 2 and 1, not an InvalidCastException"
  )
}
