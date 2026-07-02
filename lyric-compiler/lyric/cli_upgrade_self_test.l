//! cli_upgrade_self_test.l — exercises Lyric.Cli.cmdUpgrade argument parsing,
//! conflict validation, dry-run execution paths, and the pure GitHub
//! Releases version-resolution helpers (#4589) via the `@test_module` runner.
//!
//! Runs in CI via:
//!
//!   lyric test lyric-compiler/lyric/cli_upgrade_self_test.l
//!
//! Note: "dry-run github custom dir" below exercises the `--dry-run`,
//! no-`--version` path, which makes a best-effort (network-optional) live
//! call to the GitHub Releases API to preview the resolved version — see
//! `runGithubUpgrade` in cli_upgrade.l. It asserts success either way
//! (online or offline) since the dry-run path degrades gracefully rather
//! than failing when the lookup is unavailable. No test in this file
//! exercises a REAL (non-dry-run) GitHub install: `cmdUpgrade` requires an
//! explicit `--version` for that path specifically so this suite can never
//! trigger a live self-upgrade (download + execute) as a side effect.
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

// ─── stripLeadingV (#4589) ───────────────────────────────────────────────
test "stripLeadingV: strips a lowercase v prefix" {
  assertEqual(Cli.stripLeadingV("v0.4.6"), "0.4.6", "lowercase v prefix stripped")
}

test "stripLeadingV: strips an uppercase V prefix" {
  assertEqual(Cli.stripLeadingV("V0.4.6"), "0.4.6", "uppercase V prefix stripped")
}

test "stripLeadingV: leaves a bare version unchanged" {
  assertEqual(Cli.stripLeadingV("0.4.6"), "0.4.6", "no prefix to strip")
}

test "stripLeadingV: empty string is unchanged" {
  assertEqual(Cli.stripLeadingV(""), "", "empty string handled without indexing past the end")
}

// ─── extractTagNameFromReleaseJson (#4589) ──────────────────────────────
test "extractTagNameFromReleaseJson: typical GitHub API response shape" {
  val json = "{\n  \"url\": \"https://api.github.com/repos/nichobbs/lyric-lang/releases/123\",\n" +
    "  \"tag_name\": \"v0.4.6\",\n  \"name\": \"v0.4.6\",\n  \"draft\": false\n}\n"
  match Cli.extractTagNameFromReleaseJson(json) {
    case Some(tag) -> assertEqual(tag, "v0.4.6", "tag_name extracted from a realistic response body")
    case None -> assertTrue(false, "expected Some(\"v0.4.6\"), got None")
  }
}

test "extractTagNameFromReleaseJson: compact JSON with no spacing" {
  val json = "{\"tag_name\":\"v1.2.3\",\"draft\":false}"
  match Cli.extractTagNameFromReleaseJson(json) {
    case Some(tag) -> assertEqual(tag, "v1.2.3", "tag_name extracted from compact JSON")
    case None -> assertTrue(false, "expected Some(\"v1.2.3\"), got None")
  }
}

test "extractTagNameFromReleaseJson: missing tag_name field yields None" {
  val json = "{\"message\": \"Not Found\"}"
  match Cli.extractTagNameFromReleaseJson(json) {
    case Some(tag) -> assertTrue(false, "expected None, got Some(\"" + tag + "\")")
    case None -> ()
  }
}

test "extractTagNameFromReleaseJson: malformed JSON yields None" {
  match Cli.extractTagNameFromReleaseJson("not json at all") {
    case Some(tag) -> assertTrue(false, "expected None, got Some(\"" + tag + "\")")
    case None -> ()
  }
}

test "extractTagNameFromReleaseJson: empty tag_name value yields None" {
  val json = "{\"tag_name\": \"\"}"
  match Cli.extractTagNameFromReleaseJson(json) {
    case Some(tag) -> assertTrue(false, "expected None for an empty tag_name, got Some(\"" + tag + "\")")
    case None -> ()
  }
}
