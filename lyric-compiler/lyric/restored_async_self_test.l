//! restored_async_self_test.l — regression tests for cross-assembly calls to
//! restored `async func`s (#5561).
//!
//! A restored async func's DLL method is the state-machine kickoff and
//! returns `Task` / `Task`1<T>`, never the bare declared T.  Contract-
//! metadata reprs do not carry asyncness, so before the fix the consumer's
//! MemberRef encoded the unwrapped declared return (`Int`, `String`, void)
//! and every call faulted at run time with
//!   MissingMethodException: Method not found:
//!     'System.Int32 CpAsync.Lib.Program.addAsync(...)'.
//! The fix derives asyncness from the producer DLL's own MethodDef metadata
//! (`Mdr.dllTaskReturningFuncs`), encodes the Task-wrapped kickoff return in
//! the MemberRef, and records it in `funcRetTypes` so the caller-side
//! `await` unwraps exactly like an in-bundle cross-package async call.
//!
//! Each test builds a PRODUCER DLL (async funcs) in-process via
//! `Lyric.Emitter.emitProject`, then builds a CONSUMER that imports the
//! producer as a restored dep, runs it, and asserts the printed output —
//! the same harness as `cross_package_generics_self_test.l`.
//!
//! Run via native `lyric test` with LYRIC_LOAD_COMPILER=1 (required because
//! the test imports `Lyric.Emitter`, a compiler package):
//!   LYRIC_LOAD_COMPILER=1 lyric test lyric-compiler/lyric/restored_async_self_test.l
//!
@test_module
package Lyric.RestoredAsyncSelfTest

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

// ─── Helpers (same shape as cross_package_generics_self_test.l) ──────────────
func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", Environment.getVarOrDefault("TEMP", Environment.getVarOrDefault("TMP", "/tmp")))
}

func freshTempDir(label: in String): String {
  val root = Path.join(tempBase(), "lyric-cpasync-" + label + "-" + uuidToString(newUuid()))
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

// The shared producer: one async func per return shape under test.
func producerSource(pkg: in String): String {
  "package " + pkg + "\n" + "\n" + "pub async func addAsync(a: in Int, b: in Int): Int {\n" + "  a + b\n" + "}\n" + "\n" +
    "pub async func greetAsync(name: in String): String {\n" +
    "  \"hello \" + name\n" +
    "}\n" +
    "\n" +
    "pub async func pingAsync(): Unit {\n" +
    "  println(\"pong\")\n" +
    "}\n"
}

// ─── Tests ───────────────────────────────────────────────────────────────────
// Scalar (Int) return: the MemberRef must encode Task`1<int32>, and the
// blocking await in the non-async consumer main must unwrap it.
test "restored async func returning Int round-trips through await" {
  val tmpDir = freshTempDir("int")
  val producerDll = buildDll(tmpDir, "CpAsync.Lib", producerSource("CpAsync.Lib"), "CpAsync.Lib")
  val consumerSrc = "package CpAsync.App\n" + "\n" + "import CpAsync.Lib\n" + "\n" + "func main(): Unit {\n" +
    "  val r = await addAsync(20, 22)\n" +
    "  println(r)\n" +
    "}\n"
  val captured = buildAndRunConsumer(tmpDir, "CpAsync.App", consumerSrc, "CpAsync.App", "CpAsync.Lib", producerDll)
  cleanup(tmpDir)
  assertEqualInt(captured.exitCode, 0, "cpasync_int: exit 0 (stderr=" + captured.stderr + ")")
  assertEqual(Str.trim(captured.stdout), "42", "cpasync_int: stdout = 42")
}

// Reference (String) return: Task`1<string> kickoff shape.
test "restored async func returning String round-trips through await" {
  val tmpDir = freshTempDir("str")
  val producerDll = buildDll(tmpDir, "CpAsync.StrLib", producerSource("CpAsync.StrLib"), "CpAsync.StrLib")
  val consumerSrc = "package CpAsync.StrApp\n" + "\n" + "import CpAsync.StrLib\n" + "\n" + "func main(): Unit {\n" +
    "  println(await greetAsync(\"restored\"))\n" +
    "}\n"
  val captured = buildAndRunConsumer(
    tmpDir,
    "CpAsync.StrApp",
    consumerSrc,
    "CpAsync.StrApp",
    "CpAsync.StrLib",
    producerDll
  )
  cleanup(tmpDir)
  assertEqualInt(captured.exitCode, 0, "cpasync_str: exit 0 (stderr=" + captured.stderr + ")")
  assertEqual(Str.trim(captured.stdout), "hello restored", "cpasync_str: stdout = hello restored")
}

// Unit return: the kickoff returns the non-generic Task; the call site must
// not treat it as void (the Task IS on the stack) and await must block on it.
test "restored async func returning Unit completes through await" {
  val tmpDir = freshTempDir("unit")
  val producerDll = buildDll(tmpDir, "CpAsync.UnitLib", producerSource("CpAsync.UnitLib"), "CpAsync.UnitLib")
  val consumerSrc = "package CpAsync.UnitApp\n" + "\n" + "import CpAsync.UnitLib\n" + "\n" + "func main(): Unit {\n" +
    "  await pingAsync()\n" +
    "  println(\"done\")\n" +
    "}\n"
  val captured = buildAndRunConsumer(
    tmpDir,
    "CpAsync.UnitApp",
    consumerSrc,
    "CpAsync.UnitApp",
    "CpAsync.UnitLib",
    producerDll
  )
  cleanup(tmpDir)
  assertEqualInt(captured.exitCode, 0, "cpasync_unit: exit 0 (stderr=" + captured.stderr + ")")
  assertEqual(Str.trim(captured.stdout), "pong\ndone", "cpasync_unit: stdout = pong then done")
}

// Awaiting a restored async func from inside the consumer's own `async func`
// exercises the Phase-B state-machine awaiter path against the restored
// Task`1<int32>, not just the blocking shim in a plain main.
test "restored async func awaited inside an async consumer func" {
  val tmpDir = freshTempDir("sm")
  val producerDll = buildDll(tmpDir, "CpAsync.SmLib", producerSource("CpAsync.SmLib"), "CpAsync.SmLib")
  val consumerSrc = "package CpAsync.SmApp\n" + "\n" + "import CpAsync.SmLib\n" + "\n" + "async func go(): Int {\n" +
    "  val a = await addAsync(1, 2)\n" +
    "  val b = await addAsync(a, 39)\n" +
    "  b\n" +
    "}\n" +
    "\n" +
    "func main(): Unit {\n" +
    "  println(await go())\n" +
    "}\n"
  val captured = buildAndRunConsumer(
    tmpDir,
    "CpAsync.SmApp",
    consumerSrc,
    "CpAsync.SmApp",
    "CpAsync.SmLib",
    producerDll
  )
  cleanup(tmpDir)
  assertEqualInt(captured.exitCode, 0, "cpasync_sm: exit 0 (stderr=" + captured.stderr + ")")
  assertEqual(Str.trim(captured.stdout), "42", "cpasync_sm: stdout = 42")
}
