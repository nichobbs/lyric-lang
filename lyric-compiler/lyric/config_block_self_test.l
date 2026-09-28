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
//! ── `Std.Environment.setVar` and the REQUIRED/env-override cases ─────────
//! `Std.Environment.setVar` used to be a documented no-op on `--target jvm`
//! (`hostSetEnvironmentVariable`: "SetEnvironmentVariable has no portable
//! JVM equivalent... This is a no-op stub"); #7577 gave it a process-wide
//! overlay (`Std.EnvironmentHost.envOverlay`) that `Std.Environment.getVar`
//! consults, but a `config { }` block's `<clinit>` read `System.getenv`
//! directly on `--target jvm`, bypassing that overlay entirely (#7594) — so
//! `Env.setVar` still had no observable effect on a config field's value
//! there.  #7594 fixed `Jvm.Lowering.lowerConfigBlock` to check the overlay
//! first (mirroring `hostGetVarOpt`'s own logic, inlined as raw bytecode)
//! and `Jvm.Bridge` to force `Std.EnvironmentHost` into the JVM bundle
//! whenever a compilation unit has a `config { }` block (or the `getstatic`
//! this needs dangles for a file that never itself imports
//! `Std.Environment`). The `setVar` case below pins the overlay half on
//! both targets; this file imports `Std.Environment`, so the bundling half
//! is pinned separately by `config_block_no_env_import_self_test.l`.
//!
//! The REQUIRED field and the plain env-override cases below still read env
//! vars the harness exports into the process environment BEFORE `lyric
//! test` runs (inherited by the `java` subprocess `--target jvm` shells out
//! to), not vars set from inside the test body — this exercises the
//! `System.getenv`/`GetEnvironmentVariable` FALLBACK path (an env var the
//! overlay was never told about), which is just as load-bearing a case as
//! the overlay path itself and needs no `Env.setVar` to exercise. Export
//! before running EITHER target:
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
//! The required-field-missing exit(78) path (#6200) needs a genuinely
//! separate subprocess (the abort happens inside a static initializer
//! that runs before `main`, so it can't be observed in-process) and pulls
//! in `Lyric.Emitter`, which the JVM checker can't currently resolve a
//! qualified `Emitter.ProjectPackage` type reference from — so that case
//! lives in the dotnet-only companion file `config_block_missing_required_self_test.l`
//! instead of here, to keep this file's dual-target coverage intact.
//! Imports only `Std.*`.
@test_module
package Lyric.ConfigBlockSelfTest

import Std.Core
import Std.Environment as Env
import Std.Testing

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

// #7594: `Env.setVar` set at RUNTIME (not exported into the process before
// `lyric test` runs, unlike `Overrides`/`Required`/`EmptyOverride` above)
// must be observed by a config field's env read on BOTH targets. Its own
// config block, so no earlier method touching `SetVarOverride` could run
// its `<clinit>`/static initializer before the `setVar` call below —
// exactly the same "set and read in separate test methods, no earlier
// reference" discipline `config_templates_self_test.l` /
// `webtls_config_tests.l` use for their own env-override cases.
config SetVarOverride {
  host: String = "default-setvar-host"
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

test "set the SetVarOverride env override before SetVarOverride is first touched" {
  Env.setVar("LYRIC_CONFIG_LYRIC_CONFIGBLOCKSELFTEST_SETVAROVERRIDE_HOST", "from-setvar")
  assertTrue(true, "env override set for the paired read below")
}

test "Env.setVar's overlay is observed by a config block field, on both targets (#7594)" {
  assertEqual(SetVarOverride.host, "from-setvar", "setVar's overlay wins over the declared default")
}
