//! config_block_missing_required_self_test.l — required-field-missing
//! exit(78) coverage for `config { }` blocks (#6200), split out of
//! `config_block_self_test.l`.
//!
//! The documented exit(78) path only fires inside a static initializer
//! (`.cctor` / `<clinit>`) that runs before `main` does anything with the
//! field — so it can't be observed in-process the way every other
//! `config_block_self_test.l` case is; it needs a genuinely separate
//! process whose environment lacks the field's env var. These two tests
//! compile a tiny fixture package IN-PROCESS via `Lyric.Emitter` (mirroring
//! `emitter_project_self_test.l`'s `runEmitProject*` helpers) and run the
//! produced binary/jar as a child process, asserting its exit code — the
//! fixture's env var is never exported anywhere in this file or its CI
//! wiring, so the child inherits an environment where it is genuinely
//! unset.
//!
//! This pulls in `Lyric.Emitter`, and the type checker's JVM path cannot
//! currently resolve a qualified `Emitter.ProjectPackage` type reference
//! (`error[T0014]: unknown qualified type 'Lyric.Emitter.ProjectPackage'`),
//! so — unlike `config_block_self_test.l` — this file compiles (as the
//! OUTER test module) via `--target dotnet` ONLY. Both targets' exit(78)
//! behavior are still covered: the two test bodies below target the NESTED
//! fixture at `Emitter.Dotnet` and `Emitter.Jvm` respectively, run via
//! `dotnet exec` / `java -jar`.
//!
//! CI placement (#6319 follow-up): this does the SAME kind of heavy nested
//! in-process compile as `emitter_project_self_test.l` and
//! `generic_extern_valuetype_instance_self_test.l`, so it runs alongside
//! them in `compiler-self-tests-dotnet-b`, gated behind that job's "wait for
//! parallel tests before heavy project self-tests" barrier — NOT in
//! `compiler-self-tests-dotnet-a`'s `background: true` pool. Running it
//! there once, competing with ~40 other concurrent background steps,
//! produced a corrupted/incomplete JVM fixture under memory pressure (exit 1
//! instead of the documented 78) even though the identical code passes
//! reliably unloaded — the exact class of failure that barrier exists to
//! prevent (see the "batch-2a-split" comments elsewhere in ci.yml for the
//! same root cause hitting a different pair of tests).
//!
//!   lyric test lyric-compiler/lyric/config_block_missing_required_self_test.l
@test_module
package Lyric.ConfigBlockMissingRequiredSelfTest

import Std.Core
import Std.Collections
import Std.File as File
import Std.Path as Path
import Std.ProcessCapture as Capture
import Std.Testing
import Std.Uuid
import Std.Environment as Env
import Lyric.Emitter as Emitter

func tempBase(): String {
  Env.getVarOrDefault("TMPDIR", Env.getVarOrDefault("TEMP", Env.getVarOrDefault("TMP", "/tmp")))
}

func freshTempDir(label: in String): String {
  val root = Path.join(tempBase(), "lyric-cfgblock-" + label + "-" + uuidToString(newUuid()))
  match File.createDir(root) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create temp dir " + root + ": " + IOError.message(e))
  }
  root
}

func cleanupDir(dir: in String): Unit {
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

func writeRuntimeConfigBeside(dllPath: in String): Unit {
  val dir = Path.dirname(dllPath)
  val base = Path.basename(dllPath)
  val stem = if base.endsWith(".dll") { base.substring(0, base.length - 4) } else { base }
  val cfgPath = Path.join(dir, stem + ".runtimeconfig.json")
  match File.writeText(cfgPath, runtimeConfigJson()) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot write runtimeconfig beside " + dllPath + ": " + IOError.message(e))
  }
}

// The fixture: a required config field with NO default and no matching env
// var anywhere in this test file or its CI wiring — `LYRIC_CONFIG_` +
// `CONFIGMISSINGFIXTURE_REQUIRED_SECRET` is never set, so whichever process
// runs this fixture sees it genuinely absent. `main` reads the field so the
// static initializer (`.cctor` / `<clinit>`) is guaranteed to run before
// anything else, and — per `lowerMConfig`'s absent-required branch — abort
// with exit code 78 before `println` ever executes.
func missingRequiredFixtureSource(): String {
  "package ConfigMissingFixture\n\n" + "config Required {\n" + "  secret: String\n" + "}\n\n" + "func main(): Unit {\n" +
    "  println(Required.secret)\n" +
    "}\n"
}

test "required field with no default and no env var exits 78 (subprocess, dotnet)" {
  val dir = freshTempDir("required-missing-dotnet")
  defer {
    cleanupDir(dir)
  }
  val dllPath = Path.join(dir, "ConfigMissingFixture.dll")
  val srcs: List[String] = newList()
  srcs.add(missingRequiredFixtureSource())
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(Emitter.ProjectPackage(name = "ConfigMissingFixture", sources = srcs))
  val req = Emitter.EmitProjectRequest(
    packages = pkgs,
    assemblyName = "ConfigMissingFixture",
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
    case None -> panic("required-field-missing fixture: emitProject produced no output (diagnostics on stderr)")
    case Some(_) -> ()
  }
  writeRuntimeConfigBeside(dllPath)
  val args: List[String] = newList()
  args.add("exec")
  args.add(dllPath)
  val captured = Capture.runCaptureWithDiagnostics("dotnet", args, "")
  // Always print stdout/stderr (not just embedded in the assertion's failure
  // message) — the child's OWN diagnostics are the only way to tell "genuine
  // exit(78) mismatch" apart from "the fixture crashed before it even got
  // there" when this runs somewhere the fixture behaves unexpectedly (#6319
  // follow-up).
  println("dotnet fixture stdout: " + captured.stdout)
  println("dotnet fixture stderr: " + captured.stderr)
  assertEqualInt(
    captured.exitCode,
    78,
    "required config field with no default and an unset env var exits 78 / POSIX EX_CONFIG (stderr=" + captured.stderr +
      ")"
  )
}

test "required field with no default and no env var exits 78 (subprocess, jvm)" {
  val dir = freshTempDir("required-missing-jvm")
  defer {
    cleanupDir(dir)
  }
  val jarPath = Path.join(dir, "ConfigMissingFixture.jar")
  val srcs: List[String] = newList()
  srcs.add(missingRequiredFixtureSource())
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(Emitter.ProjectPackage(name = "ConfigMissingFixture", sources = srcs))
  val req = Emitter.EmitProjectRequest(
    packages = pkgs,
    assemblyName = "ConfigMissingFixture",
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
    case None -> panic("required-field-missing fixture (jvm): emitProject produced no output (diagnostics on stderr)")
    case Some(_) -> ()
  }
  val args: List[String] = newList()
  args.add("-jar")
  args.add(jarPath)
  val captured = Capture.runCaptureWithDiagnostics("java", args, "")
  // See the dotnet test above for why these are printed unconditionally.
  println("jvm fixture stdout: " + captured.stdout)
  println("jvm fixture stderr: " + captured.stderr)
  assertEqualInt(
    captured.exitCode,
    78,
    "required config field with no default and an unset env var exits 78 / POSIX EX_CONFIG on jvm (stderr=" +
      captured.stderr +
      ")"
  )
}
