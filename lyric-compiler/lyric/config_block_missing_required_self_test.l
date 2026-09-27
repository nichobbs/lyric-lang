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
  val paths: List[String] = newList()
  paths.add("")
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(Emitter.ProjectPackage(name = "ConfigMissingFixture", sources = srcs, paths = paths))
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
    defines = newList(),
    packageFeatures = Emitter.noPackageFeatures()
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
  val paths: List[String] = newList()
  paths.add("")
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(Emitter.ProjectPackage(name = "ConfigMissingFixture", sources = srcs, paths = paths))
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
    defines = newList(),
    packageFeatures = Emitter.noPackageFeatures()
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

// #7229: range-refined config fields.  The fixture reads one ranged field of
// each numeric type (Int, Long, Float, Double), since each has its own
// comparison lowering on both backends;
// each run sets their env vars through `env` so the child sees exactly the
// value under test.  An out-of-range or NaN value must abort in the static
// initializer with exit 78 (G0004) before `main` prints anything.
func rangedFixtureSource(): String {
  "package ConfigRangeFixture\n\n" + "config Limits {\n" + "  port: Int range 1 ..= 65535 = 8080\n" +
    "  ratio: Double range 0.0 ..< 1.0 = 0.5\n" +
    "  quota: Long range 1 ..= 10000000000 = 5000000000i64\n" +
    "  scale: Float range 0.5 ..= 2.0 = 1.0f32\n" +
    "}\n\n" +
    "func main(): Unit {\n" +
    "  println(\"port=\" + toString(Limits.port))\n" +
    "  println(\"ratio=\" + toString(Limits.ratio))\n" +
    "  println(\"quota=\" + toString(Limits.quota))\n" +
    "  println(\"scale=\" + toString(Limits.scale))\n" +
    "}\n"
}

func emitRangedFixture(dir: in String, target: in Emitter.CompileTarget, outName: in String): String {
  val outPath = Path.join(dir, outName)
  val srcs: List[String] = newList()
  srcs.add(rangedFixtureSource())
  val paths: List[String] = newList()
  paths.add("")
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(Emitter.ProjectPackage(name = "ConfigRangeFixture", sources = srcs, paths = paths))
  val req = Emitter.EmitProjectRequest(
    packages = pkgs,
    assemblyName = "ConfigRangeFixture",
    outputPath = outPath,
    target = target,
    restoredDllPaths = newList(),
    activeFeatures = newList(),
    declaredFeatures = newList(),
    packageVersion = "",
    depTemplateSrcs = newList(),
    nugetAssemblyPaths = newList(),
    defines = newList()
  )
  match Emitter.emitProject(req).outputPath {
    case None -> panic("ranged config fixture: emitProject produced no output (diagnostics on stderr)")
    case Some(_) -> ()
  }
  outPath
}

// Run `runner args…` under `env <assignments>` and return the capture.
func runRangedFixture(
  assignments: in List[String], runner: in String, runnerArgs: in List[String]
): Capture.CaptureResult {
  val args: List[String] = newList()
  for a in assignments.toArray() {
    args.add(a)
  }
  args.add(runner)
  for a in runnerArgs.toArray() {
    args.add(a)
  }
  val captured = Capture.runCaptureWithDiagnostics("env", args, "")
  println("ranged fixture stdout: " + captured.stdout)
  println("ranged fixture stderr: " + captured.stderr)
  captured
}

func assertRangedFixtureRuns(label: in String, runner: in String, runnerArgs: in List[String]): Unit {
  val portVar = "LYRIC_CONFIG_CONFIGRANGEFIXTURE_LIMITS_PORT="
  val ratioVar = "LYRIC_CONFIG_CONFIGRANGEFIXTURE_LIMITS_RATIO="

  val outOfRange: List[String] = newList()
  outOfRange.add(portVar + "70000")
  val bad = runRangedFixture(outOfRange, runner, runnerArgs)
  assertEqualInt(bad.exitCode, 78, label + ": an out-of-range Int exits 78 (stderr=" + bad.stderr + ")")
  assertTrue(bad.stderr.contains("Limits.port"), label + ": the message names the field")
  assertTrue(bad.stderr.contains("[1, 65535]"), label + ": the message gives the range")
  assertTrue(not bad.stdout.contains("port="), label + ": main does not run")

  val inRange: List[String] = newList()
  inRange.add(portVar + "443")
  val good = runRangedFixture(inRange, runner, runnerArgs)
  assertEqualInt(good.exitCode, 0, label + ": an in-range Int starts (stderr=" + good.stderr + ")")
  assertTrue(good.stdout.contains("port=443"), label + ": the env value is used")
  assertTrue(good.stdout.contains("ratio=0.5"), label + ": the in-range default is used")

  val nanRatio: List[String] = newList()
  nanRatio.add(ratioVar + "NaN")
  val nan = runRangedFixture(nanRatio, runner, runnerArgs)
  assertEqualInt(nan.exitCode, 78, label + ": NaN is outside a Double range (stderr=" + nan.stderr + ")")
  assertTrue(nan.stderr.contains("Limits.ratio"), label + ": the NaN message names the field")

  val quotaVar = "LYRIC_CONFIG_CONFIGRANGEFIXTURE_LIMITS_QUOTA="
  val scaleVar = "LYRIC_CONFIG_CONFIGRANGEFIXTURE_LIMITS_SCALE="

  val bigQuota: List[String] = newList()
  bigQuota.add(quotaVar + "10000000001")
  val q = runRangedFixture(bigQuota, runner, runnerArgs)
  assertEqualInt(q.exitCode, 78, label + ": a Long above its bound exits 78 (stderr=" + q.stderr + ")")
  assertTrue(q.stderr.contains("Limits.quota"), label + ": the Long message names the field")

  val okQuota: List[String] = newList()
  okQuota.add(quotaVar + "10000000000")
  okQuota.add(scaleVar + "2.0")
  val q2 = runRangedFixture(okQuota, runner, runnerArgs)
  assertEqualInt(q2.exitCode, 0, label + ": inclusive Long and Float bounds start (stderr=" + q2.stderr + ")")
  assertTrue(q2.stdout.contains("quota=10000000000"), label + ": the Long env value is used")

  val lowScale: List[String] = newList()
  lowScale.add(scaleVar + "0.25")
  val sc = runRangedFixture(lowScale, runner, runnerArgs)
  assertEqualInt(sc.exitCode, 78, label + ": a Float below its bound exits 78 (stderr=" + sc.stderr + ")")
  assertTrue(sc.stderr.contains("Limits.scale"), label + ": the Float message names the field")

  val nanScale: List[String] = newList()
  nanScale.add(scaleVar + "NaN")
  val sn = runRangedFixture(nanScale, runner, runnerArgs)
  assertEqualInt(sn.exitCode, 78, label + ": NaN is outside a Float range (stderr=" + sn.stderr + ")")
}

test "range-refined config fields are checked at startup (subprocess, dotnet)" {
  val dir = freshTempDir("ranged-dotnet")
  defer {
    cleanupDir(dir)
  }
  val dllPath = emitRangedFixture(dir, Emitter.Dotnet, "ConfigRangeFixture.dll")
  writeRuntimeConfigBeside(dllPath)
  val runnerArgs: List[String] = newList()
  runnerArgs.add("exec")
  runnerArgs.add(dllPath)
  assertRangedFixtureRuns("dotnet", "dotnet", runnerArgs)
}

test "range-refined config fields are checked at startup (subprocess, jvm)" {
  val dir = freshTempDir("ranged-jvm")
  defer {
    cleanupDir(dir)
  }
  val jarPath = emitRangedFixture(dir, Emitter.Jvm, "ConfigRangeFixture.jar")
  val runnerArgs: List[String] = newList()
  runnerArgs.add("-jar")
  runnerArgs.add(jarPath)
  assertRangedFixtureRuns("jvm", "java", runnerArgs)
}
