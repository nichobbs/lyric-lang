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
package Lyric.RestoredGenericFieldWriteSelfTest

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
  val root = Path.join(tempBase(), "lyric-restored-genfield-" + label + "-" + uuidToString(newUuid()))
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

// ─── Sources ─────────────────────────────────────────────────────────────────
func libSource(): String {
  "package Rd.Lib\n\n" + "pub ref record Cell[T] {\n  var value: T\n}\n\n" +
    "pub ref record Pair[A, B] {\n  var first: A\n  var second: B\n  tag: Int\n}\n"
}

func appSource(): String {
  "package Rd.App\n\n" + "import Std.Core\nimport Rd.Lib\n\n" + "func main(): Unit {\n" +
    "  val c: Cell[Int] = Cell(value = 1)\n" +
    "  c.value = 7\n" +
    "  println(toString(c.value))\n" +
    "  c.value += 5\n" +
    "  println(toString(c.value))\n" +
    "  var d: Cell[String] = Cell(value = \"a\")\n" +
    "  d.value = \"b\"\n" +
    "  println(d.value)\n" +
    "  val p: Pair[Int, String] = Pair(first = 2, second = \"x\", tag = 9)\n" +
    "  p.first += 40\n" +
    "  p.second = \"y\"\n" +
    "  p.first = p.first * 2\n" +
    "  println(toString(p.first) + p.second + toString(p.tag))\n" +
    "}\n"
}

func expected(): List[String] {
  val e: List[String] = newList()
  e.add("7")
  e.add("12")
  e.add("b")
  e.add("84y9")
  e
}

test "restored generic record var field writes on dotnet" {
  assertLines("dotnet", runRestored("gfw", false, libSource(), appSource()), expected())
}

test "restored generic record var field writes on the JVM" {
  assertLines("jvm", runRestored("gfw", true, libSource(), appSource()), expected())
}
