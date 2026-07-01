//! cli_upgrade_self_test.l — exercises Lyric.Cli.cmdUpgrade argument parsing,
//! conflict validation, and dry-run execution paths via the `@test_module` runner.
//!
//! Runs in CI via:
//!
//!   lyric test lyric-compiler/lyric/cli_upgrade_self_test.l
//!
@test_module
package Lyric.CliUpgradeSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Lyric.Cli as Cli

test "cli_upgrade: conflicting nuget and github options → error" {
  val argv = ["upgrade", "--nuget", "--github"]
  assertEqualInt(Cli.cmdUpgrade(argv), 1, "conflicting channels")
}

test "cli_upgrade: missing version value → error" {
  val argv = ["upgrade", "--version"]
  assertEqualInt(Cli.cmdUpgrade(argv), 1, "missing version value")
}

test "cli_upgrade: missing dir value → error" {
  val argv = ["upgrade", "--dir"]
  assertEqualInt(Cli.cmdUpgrade(argv), 1, "missing dir value")
}

test "cli_upgrade: unknown argument → error" {
  val argv = ["upgrade", "--invalid-flag"]
  assertEqualInt(Cli.cmdUpgrade(argv), 1, "invalid argument")
}

test "cli_upgrade: dir specified with nuget → error" {
  val argv = ["upgrade", "--nuget", "--dir", "/tmp"]
  assertEqualInt(Cli.cmdUpgrade(argv), 1, "dir with nuget")
}

test "cli_upgrade: dry-run nuget → success" {
  val argv = ["upgrade", "--dry-run", "--nuget"]
  assertEqualInt(Cli.cmdUpgrade(argv), 0, "dry-run nuget")
}

test "cli_upgrade: dry-run github version → success" {
  val argv = ["upgrade", "--dry-run", "--github", "--version", "0.4.6"]
  assertEqualInt(Cli.cmdUpgrade(argv), 0, "dry-run github version")
}

test "cli_upgrade: dry-run github custom dir → success" {
  val argv = ["upgrade", "--dry-run", "--github", "--dir", "/tmp"]
  assertEqualInt(Cli.cmdUpgrade(argv), 0, "dry-run github custom dir")
}

test "cli_upgrade: github upgrade without version and without dry-run → error" {
  val argv = ["upgrade", "--github"]
  assertEqualInt(Cli.cmdUpgrade(argv), 1, "missing version for github upgrade")
}


