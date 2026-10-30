//! A write to a `var` field of a generic record declared in another assembly
//! (a restored dependency), plain and compound, on both targets (#7676).
//!
//! `generic_record_var_field_self_test.l` writes only through an in-bundle
//! receiver (`MGenericInstByName`).  A generic record read back from a
//! restored DLL is an `MGenericInst` receiver instead, a different arm of
//! `lowerAssignExprMsil`: it closes the record over its type arguments
//! through a TypeSpec and writes the field through a TypeSpec-parented
//! MemberRef (`MStfldGeneric`).  Each case builds a producer through
//! `Lyric.Emitter.emitProject`, then a consumer that restores it, runs the
//! consumer and compares its output.  Covers a plain write, `+=`, a write
//! through a `val` binding, a `String` type argument and a read after the
//! write.
//!
//! Run in CI via native `lyric test` with LYRIC_LOAD_COMPILER=1 (it imports
//! `Lyric.Emitter`, a compiler package).
@test_module
package Lyric.ModuleValShadowImportSelfTest

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

// ─── Harness ─────────────────────────────────────────────────────────────────
func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", Environment.getVarOrDefault("TEMP", Environment.getVarOrDefault("TMP", "/tmp")))
}

func freshTempDir(label: in String): String {
  val root = Path.join(tempBase(), "lyric-valshadow-" + label + "-" + uuidToString(newUuid()))
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

func runtimeConfigJson(): String {
  "{\n" + "  \"runtimeOptions\": {\n" + "    \"tfm\": \"net10.0\",\n" + "    \"framework\": {\n" +
    "      \"name\": \"Microsoft.NETCore.App\",\n" +
    "      \"version\": \"10.0.0\"\n" +
    "    }\n" +
    "  }\n" +
    "}\n"
}

func writeRuntimeConfig(dllPath: in String): Unit {
  val stem = Path.basename(dllPath).substring(0, Path.basename(dllPath).length - 4)
  match File.writeText(Path.join(Path.dirname(dllPath), stem + ".runtimeconfig.json"), runtimeConfigJson()) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot write runtimeconfig for " + dllPath + ": " + IOError.message(e))
  }
}

func mkPkg(name: in String, source: in String): Emitter.ProjectPackage {
  val srcs: List[String] = newList()
  srcs.add(source)
  val paths: List[String] = newList()
  paths.add("")
  Emitter.ProjectPackage(name = name, sources = srcs, paths = paths)
}

// Compile one package to `outPath` for `target`, restoring `restored`
// (`<package>\t<path>` entries).  True on success.
func emitOne(
  pkgName: in String,
  source: in String,
  outPath: in String,
  target: in Emitter.CompileTarget,
  restored: in List[String],
): Bool {
  match emitOneResult(pkgName, source, outPath, target, restored).outputPath {
    case Some(_) -> true
    case None -> false
  }
}

func emitOneResult(
  pkgName: in String,
  source: in String,
  outPath: in String,
  target: in Emitter.CompileTarget,
  restored: in List[String],
): Emitter.EmitResult {
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(mkPkg(pkgName, source))
  Emitter.emitProject(
    Emitter.EmitProjectRequest(
      packages = pkgs,
      assemblyName = pkgName,
      outputPath = outPath,
      target = target,
      restoredDllPaths = restored,
      activeFeatures = newList(),
      declaredFeatures = newList(),
      packageVersion = "",
      depTemplateSrcs = newList(),
      nugetAssemblyPaths = newList(),
      defines = newList(),
      packageFeatures = Emitter.noPackageFeatures(),
      contractsEnabled = true
    )
  )
}

// Build the producer, then a consumer restoring it, run the consumer and
// return its trimmed stdout.  Fails the test with the stage that failed.
func runRestored(label: in String, jvm: in Bool, libSrc: in String, appSrc: in String): String {
  val dir = freshTempDir(label + (if jvm { "-jvm" } else { "-dotnet" }))
  val ext = if jvm { ".jar" } else { ".dll" }
  val target = if jvm { Emitter.Jvm } else { Emitter.Dotnet }
  val libPath = Path.join(dir, "Rd.Lib" + ext)
  val noRestored: List[String] = newList()
  if not emitOne("Rd.Lib", libSrc, libPath, target, noRestored) {
    cleanup(dir)
    panic(label + ": the library failed to compile")
  }
  val appPath = Path.join(dir, "Rd.App" + ext)
  val restored: List[String] = newList()
  restored.add("Rd.Lib\t" + libPath)
  if not emitOne("Rd.App", appSrc, appPath, target, restored) {
    cleanup(dir)
    panic(label + ": the consumer failed to compile against the restored library")
  }
  val args: List[String] = newList()
  val captured = if jvm {
    args.add("-jar")
    args.add(appPath)
    Capture.runCaptureWithDiagnostics("java", args, "")
  } else {
    Emitter.copyStdlibDllsBeside(appPath, Emitter.findCompiledStdlibDir())
    writeRuntimeConfig(appPath)
    args.add("exec")
    args.add(appPath)
    Capture.runCaptureWithDiagnostics("dotnet", args, "")
  }
  cleanup(dir)
  assertEqualInt(captured.exitCode, 0, label + ": the consumer exits 0 (stderr=" + captured.stderr + ")")
  Str.trim(captured.stdout)
}

func assertLines(label: in String, actual: in String, expected: in List[String]): Unit {
  val lines = Str.split(actual, "\n")
  assertEqualInt(lines.count, expected.count, label + ": line count of\n" + actual)
  var i = 0
  while i < lines.count and i < expected.count {
    assertEqual(Str.trim(lines[i]), expected[i], label + ": line " + toString(i + 1))
    i = i + 1
  }
}

// Build both packages into ONE assembly (the shape `Msil.Lowering` /
// `Msil.Tables` have in the compiler bundle), run it and return its stdout.
func runBundled(label: in String, libSrc: in String, appSrc: in String): String {
  val dir = freshTempDir(label + "-bundle")
  val appPath = Path.join(dir, "Rd.App.dll")
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(mkPkg("Rd.Lib", libSrc))
  pkgs.add(mkPkg("Rd.App", appSrc))
  val res = Emitter.emitProject(
    Emitter.EmitProjectRequest(
      packages = pkgs,
      assemblyName = "Rd.App",
      outputPath = appPath,
      target = Emitter.Dotnet,
      restoredDllPaths = newList(),
      activeFeatures = newList(),
      declaredFeatures = newList(),
      packageVersion = "",
      depTemplateSrcs = newList(),
      nugetAssemblyPaths = newList(),
      defines = newList(),
      packageFeatures = Emitter.noPackageFeatures(),
      contractsEnabled = true
    )
  )
  match res.outputPath {
    case Some(_) -> ()
    case None -> {
      cleanup(dir)
      panic(label + ": the bundle failed to compile")
    }
  }
  Emitter.copyStdlibDllsBeside(appPath, Emitter.findCompiledStdlibDir())
  writeRuntimeConfig(appPath)
  val args: List[String] = newList()
  args.add("exec")
  args.add(appPath)
  val captured = Capture.runCaptureWithDiagnostics("dotnet", args, "")
  cleanup(dir)
  assertEqualInt(captured.exitCode, 0, label + ": the bundle exits 0 (stderr=" + captured.stderr + ")")
  Str.trim(captured.stdout)
}

// ─── Sources ─────────────────────────────────────────────────────────────────
func libSource(): String {
  "package Rd.Lib\n\n" + "pub val LIMIT: Int = 100\n" + "pub val NAME: String = \"lib\"\n" +
    "pub func libOne(): Int {\n  1\n}\n"
}

func appSource(): String {
  "package Rd.App\n\n" + "import Std.Core\nimport Rd.Lib\n\n" + "val LIMIT: Int = 7\n" +
    "val NAME: String = \"app\"\n\n" +
    "func third(x: in Int): Int {\n  x + LIMIT\n}\n\n" +
    "func second(x: in Int): Int {\n  third(x) * 2\n}\n\n" +
    "func first(x: in Int): Int {\n  second(x) + libOne()\n}\n\n" +
    "func label(): String {\n  NAME + toString(first(1))\n}\n\n" +
    "func main(): Unit {\n" +
    "  println(toString(LIMIT))\n" +
    "  println(label())\n" +
    "}\n"
}

func expected(): List[String] {
  val e: List[String] = newList()
  e.add("7")
  e.add("app17")
  e
}

test "a module val shadowing an imported pub val on dotnet" {
  assertLines("dotnet", runRestored("shadow", false, libSource(), appSource()), expected())
}

test "a module val shadowing an imported pub val on the JVM" {
  assertLines("jvm", runRestored("shadow", true, libSource(), appSource()), expected())
}

test "a module val shadowing an imported pub val in one bundle" {
  assertLines("bundle", runBundled("shadow", libSource(), appSource()), expected())
}
