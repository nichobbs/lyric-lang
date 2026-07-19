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
//! through each field's branchy `<clinit>` are exercised), and a required
//! field satisfied by an env var.
//!
//! Imports only `Std.*`.
@test_module
package Lyric.ConfigBlockSelfTest

import Std.Core
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
