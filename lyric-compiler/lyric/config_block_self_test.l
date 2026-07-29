//! config_block_self_test.l — end-to-end RUNTIME regression test for
//! docs/25-config-blocks.md module-scope `config { … }` blocks on BOTH
//! targets (#3228).
//!
//! Before this fix the JVM backend PARSED `config { … }` blocks but emitted
//! nothing for them (`jvm/codegen/06_items.l`'s `IConfig` item arm was
//! intentionally empty), so a program that read `Settings.port` compiled
//! cleanly on `--target jvm` but had no runtime field to read. The MSIL
//! backend already emitted a sealed static class initialised by a `.cctor`
//! that reads each field's env var and falls back to the declared default
//! (D-progress-488). `Jvm.Lowering.lowerConfigBlock` now mirrors that
//! `.cctor` shape with a JVM `<clinit>`: one `public static final` field per
//! config field, populated by reading `System.getenv`, falling back to the
//! literal default (or aborting with exit code 78 for a required field with
//! no value).
//!
//! This test exercises the BASE config-block mechanism only — a plain
//! module-scope block, no `pub config` template and no `config … from …`
//! instantiation. That is the scope of #3228 (see `docs/25` §2). The
//! existing `config_templates_self_test.l` covers docs/58 templates plus
//! wire-embedded config instantiation; it stays dotnet-only, unchanged,
//! since template materialisation and the wire "config-instance-as-value"
//! rewrite are outside #3228's scope.
//!
//! ── Why no `Std.Environment.setVar` here ──────────────────────────────────
//! `config_templates_self_test.l` sets its env-var overrides at runtime via
//! `Env.setVar`. That works on `--target dotnet` (the CLR supports real
//! `SetEnvironmentVariable`), but `Std.Environment.setVar` is a DOCUMENTED
//! no-op on `--target jvm` (`lyric-stdlib/std/_kernel_jvm/environment_host.l`
//! `hostSetEnvironmentVariable`: "SetEnvironmentVariable has no portable JVM
//! equivalent... This is a no-op stub") — a pre-existing, unrelated JVM
//! stdlib limitation, not something #3228 touches. So the REQUIRED field and
//! the env-override cases here read env vars the harness exports into the
//! process environment BEFORE `lyric test` runs (inherited by the `java`
//! subprocess `--target jvm` shells out to), not vars set from inside the
//! test body. Export before running EITHER target:
//!
//!   export LYRIC_CONFIG_LYRIC_CONFIGBLOCKSELFTEST_OVERRIDES_PORT=9090
//!   export LYRIC_CONFIG_LYRIC_CONFIGBLOCKSELFTEST_OVERRIDES_LIMIT=4294967296
//!   export LYRIC_CONFIG_LYRIC_CONFIGBLOCKSELFTEST_OVERRIDES_RATE=2.5
//!   export LYRIC_CONFIG_LYRIC_CONFIGBLOCKSELFTEST_OVERRIDES_RATIO=3.5
//!   export LYRIC_CONFIG_LYRIC_CONFIGBLOCKSELFTEST_OVERRIDES_ENABLED=true
//!   export LYRIC_CONFIG_LYRIC_CONFIGBLOCKSELFTEST_OVERRIDES_HOST=override-host
//!   export LYRIC_CONFIG_LYRIC_CONFIGBLOCKSELFTEST_REQUIRED_SECRET=s3cr3t
//!   export LYRIC_CONFIG_LYRIC_CONFIGBLOCKSELFTEST_EMPTYOVERRIDE_HOST=
//!   lyric test lyric-compiler/lyric/config_block_self_test.l
//!   lyric test --target jvm lyric-compiler/lyric/config_block_self_test.l
//!
//! Run in CI via native `lyric test` on BOTH targets (model:
//! `bitwise_self_test.l`): `--target dotnet` compiles in-process through
//! `Msil.Bridge`, `--target jvm` compiles in-process through `Jvm.Bridge`
//! (`compileToJarBundled`) and runs under `java`. Both assert every runtime
//! config value — defaulted fields (including a negative-literal default,
//! exercising the `EPrefix(PreNeg, ELiteral(...))` folding path), an
//! env-var override for every supported field type (Int/Long/Float/Double/
//! Bool/String — both the default path and the env-override "present" path
//! through each field's branchy `<clinit>` are exercised), a required
//! field satisfied by an env var, and an env var explicitly set to the
//! empty string (`IsNullOrEmpty`/`isEmpty` treats "" the same as "absent",
//! so this must fall back to the declared default rather than trying to
//! parse "" — #6204).
//!
//! #6200 additionally covers the documented exit(78) path for a *required*
//! field with no value at all: since that can only be observed by a field
//! access that never runs (the whole point is the process aborts before
//! `main` does anything with it), it can't be exercised in-process the way
//! every other case here is — it needs a genuinely separate process whose
//! environment lacks the field's env var. The two `... (subprocess)` tests
//! below compile a tiny fixture program in-process via `Lyric.Emitter`
//! (mirroring `emitter_project_self_test.l`'s `runEmitProject*` helpers) and
//! run the produced binary as a child process, asserting its exit code —
//! the fixture's env var is never exported anywhere in this file or its CI
//! wiring, so the child inherits an environment where it is genuinely unset.
//! This pulls in `Lyric.Emitter`, so `LYRIC_LOAD_COMPILER=1` is needed for
//! `lyric test` to resolve it (both targets; see ci.yml).
@test_module
package Lyric.ConfigBlockSelfTest

import Std.Core
import Std.Collections
import Std.File as File
import Std.String as Str
import Std.Path as Path
import Std.ProcessCapture as Capture
import Std.Testing
import Std.Uuid
import Std.Environment as Env
import Lyric.Emitter as Emitter

config Defaults {
  port: Int = 8080
  limit: Long = 1099511627776
  rate: Float = 0.5
  ratio: Double = 0.25
  enabled: Bool = true
  host: String = "0.0.0.0"
  negPort: Int = -1
}

config Overrides {
  port: Int = 1
  limit: Long = 1
  rate: Float = 1.0
  ratio: Double = 1.0
  enabled: Bool = false
  host: String = "default"
}

config Required {
  secret: String
}

// #6204: an env var explicitly set to "" must be treated the same as an
// absent env var (both backends check IsNullOrEmpty/isEmpty before
// attempting to parse), so this still reads back the declared default.
config EmptyOverride {
  host: String = "default-host"
}

test "defaulted fields read back their declared defaults" {
  assertEqualInt(Defaults.port, 8080, "Int default")
  assertEqualLong(Defaults.limit, 1099511627776, "Long default")
  assertTrue(Defaults.rate == 0.5f32, "Float default")
  assertTrue(Defaults.ratio == 0.25, "Double default")
  assertTrue(Defaults.enabled, "Bool default")
  assertEqual(Defaults.host, "0.0.0.0", "String default")
  assertEqualInt(Defaults.negPort, -1, "negative Int default (EPrefix PreNeg folding)")
}

test "env-var override wins over the declared default for every field type" {
  assertEqualInt(Overrides.port, 9090, "Int override")
  assertEqualLong(Overrides.limit, 4294967296, "Long override")
  assertTrue(Overrides.rate == 2.5f32, "Float override")
  assertTrue(Overrides.ratio == 3.5, "Double override")
  assertTrue(Overrides.enabled, "Bool override")
  assertEqual(Overrides.host, "override-host", "String override")
}

test "required field satisfied by env var reads back the set value" {
  assertEqual(Required.secret, "s3cr3t", "required field")
}

test "env var explicitly set to empty string falls back to the declared default" {
  assertEqual(EmptyOverride.host, "default-host", "empty-string env var must not win over the default")
}

// ─── #6200: required-field-missing exit(78), via a subprocess fixture ───────
// (see the module doc comment above for why this needs a separate process).
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
  assertEqualInt(
    captured.exitCode,
    78,
    "required config field with no default and an unset env var exits 78 / POSIX EX_CONFIG on jvm (stderr=" +
      captured.stderr +
      ")"
  )
}
