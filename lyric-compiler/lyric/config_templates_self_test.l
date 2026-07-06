//! config_templates_self_test.l — end-to-end RUNTIME regression test for
//! docs/58 (D121) config templates: `pub config` template declaration,
//! `config Local from Template { overrides }` materialisation, the
//! synthesised record twin, env-var resolution under the LOCAL name, and
//! the value-position record-construction rewrite inside a wire graph.
//!
//! `--target dotnet` only: module-level config blocks emit runtime state
//! (static fields + env-var .cctor) only on the .NET target today — the
//! JVM config-emission gap is pre-existing (`jvm/codegen/06_items.l`
//! emits nothing for IConfig) and tracked as #3228, separately from docs/58.
//! Front-end expansion itself is target-independent and covered by
//! `wire_expand_self_test.l`; wire templates run on both targets via
//! `wire_templates_self_test.l`.
//!
//! Imports only `Std.*`.
@test_module
package Lyric.ConfigTemplatesSelfTest

import Std.Core
import Std.Collections
import Std.Environment as Env
import Std.Testing

pub config StaticFiles {
  root: String = "./public"
  cacheSeconds: Int = 3600
  fallbackToIndex: Bool = false
}

// Env-var override target: the env var derives from the LOCAL name
// (LYRIC_CONFIG_<PKG>_<LOCAL>_<FIELD>), so set it before the config
// class is first touched (its .cctor reads the environment once).
config EnvAssets from StaticFiles {
  cacheSeconds: Int = 60
}

config Assets from StaticFiles {
  root: String = "./wwwroot"
}

record Server {
  files: StaticFiles
  name: String
}

wire FileServer {
  @provided name: String
  config Files from StaticFiles {
    root: String = "./wire-local"
  }
  singleton server: Server = Server(files = Files, name = name)
  singleton fromModule: Server = Server(files = Assets, name = name)
  expose server
  expose fromModule
}

test "module-level instantiation materialises overrides and template defaults" {
  assertEqual(Assets.root, "./wwwroot", "override wins")
  assertEqualInt(Assets.cacheSeconds, 3600, "non-overridden field keeps template default")
  assertTrue(not Assets.fallbackToIndex, "bool template default preserved")
}

test "env var named after the LOCAL instantiation overrides the merged default" {
  // Must run before anything reads EnvAssets: the block's .cctor resolves
  // the environment exactly once, at first static access.
  Env.setVar("LYRIC_CONFIG_LYRIC_CONFIGTEMPLATESSELFTEST_ENVASSETS_ROOT", "/from-env")
  assertEqual(EnvAssets.root, "/from-env", "env var wins over template default")
  assertEqualInt(EnvAssets.cacheSeconds, 60, "unset env leaves declaration-site override")
}

test "config instantiation is usable as a value inside a wire graph" {
  FileServer.bootstrap("srv1")
  val s = FileServer.server()
  assertEqual(s.files.root, "./wire-local", "wire-body instantiation carries its override")
  assertEqualInt(s.files.cacheSeconds, 3600, "record twin carries template defaults")
  assertEqual(s.name, "srv1", "provided value reaches the singleton")
  val m = FileServer.fromModule()
  assertEqual(m.files.root, "./wwwroot", "module-level instantiation usable as a wire value")
}

test "record twin is constructible directly" {
  val f = StaticFiles(root = "/direct", cacheSeconds = 1, fallbackToIndex = true)
  assertEqual(f.root, "/direct", "synthesised record constructs like any record")
  assertEqualInt(f.cacheSeconds, 1, "int field")
  assertTrue(f.fallbackToIndex, "bool field")
}
