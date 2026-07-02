//! cli_version_self_test.l — exercises the pure helper functions behind
//! `lyric version --set` in `Lyric.Cli` (cli/cli_version.l):
//! `validateSemver` and `replaceVersionInToml`.  Neither does I/O, so both
//! are exercised directly against in-memory strings (issue #3982).
//!
//! Run in CI via:
//!
//!   lyric test lyric-compiler/lyric/cli_version_self_test.l
@test_module
package Lyric.CliVersionSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Lyric.Cli as Cli

// ─── validateSemver ──────────────────────────────────────────────────────
test "validateSemver: 1.0.0 is valid" {
  assertEqual(Cli.validateSemver("1.0.0"), "", "validateSemver: 1.0.0 OK")
}

test "validateSemver: 0.0.0 is valid" {
  assertEqual(Cli.validateSemver("0.0.0"), "", "validateSemver: 0.0.0 OK")
}

test "validateSemver: 1.0.0-alpha is valid (pre-release suffix)" {
  assertEqual(Cli.validateSemver("1.0.0-alpha"), "", "validateSemver: 1.0.0-alpha OK")
}

test "validateSemver: 1.0.0+build is valid (build-metadata suffix)" {
  assertEqual(Cli.validateSemver("1.0.0+build"), "", "validateSemver: 1.0.0+build OK")
}

test "validateSemver: empty string is invalid" {
  assertTrue(Cli.validateSemver("").length > 0, "validateSemver: empty is Err")
}

test "validateSemver: two-component version is invalid" {
  assertTrue(Cli.validateSemver("1.0").length > 0, "validateSemver: 1.0 is Err")
}

test "validateSemver: leading zero in PATCH is invalid" {
  assertTrue(Cli.validateSemver("1.0.07").length > 0, "validateSemver: 1.0.07 is Err (leading zero)")
}

test "validateSemver: leading zero in MAJOR is invalid" {
  assertTrue(Cli.validateSemver("01.0.0").length > 0, "validateSemver: 01.0.0 is Err (leading zero)")
}

test "validateSemver: non-numeric MINOR is invalid" {
  assertTrue(Cli.validateSemver("1.x.0").length > 0, "validateSemver: 1.x.0 is Err")
}

// ─── replaceVersionInToml ────────────────────────────────────────────────
test "replaceVersionInToml: single-section canonical spacing" {
  val text = "[package]\nname = \"Foo\"\nversion = \"0.1.0\"\n"
  match Cli.replaceVersionInToml(text, "0.1.0", "0.2.0") {
    case Err(e) -> panic("replaceVersionInToml: unexpected Err: " + e)
    case Ok(updated) -> {
      assertEqual(
        updated,
        "[package]\nname = \"Foo\"\nversion = \"0.2.0\"\n",
        "replaceVersionInToml: single-section canonical spacing"
      )
    }
  }
}

test "replaceVersionInToml: no spaces around equals" {
  val text = "[package]\nname=\"Foo\"\nversion=\"0.1.0\"\n"
  match Cli.replaceVersionInToml(text, "0.1.0", "0.2.0") {
    case Err(e) -> panic("replaceVersionInToml: unexpected Err: " + e)
    case Ok(updated) -> {
      assertEqual(updated, "[package]\nname=\"Foo\"\nversion=\"0.2.0\"\n", "replaceVersionInToml: no spaces around =")
    }
  }
}

test "replaceVersionInToml: extra spaces around equals" {
  val text = "[package]\nname   =   \"Foo\"\nversion   =   \"0.1.0\"\n"
  match Cli.replaceVersionInToml(text, "0.1.0", "0.2.0") {
    case Err(e) -> panic("replaceVersionInToml: unexpected Err: " + e)
    case Ok(updated) -> {
      assertEqual(
        updated,
        "[package]\nname   =   \"Foo\"\nversion   =   \"0.2.0\"\n",
        "replaceVersionInToml: extra spaces around ="
      )
    }
  }
}

test "replaceVersionInToml: multi-section file only touches [package]" {
  val text = "[package]\nname = \"Foo\"\nversion = \"0.1.0\"\n\n[dependencies]\n\"Bar\" = \"0.1.0\"\n"
  match Cli.replaceVersionInToml(text, "0.1.0", "0.2.0") {
    case Err(e) -> panic("replaceVersionInToml: unexpected Err: " + e)
    case Ok(updated) -> {
      assertEqual(
        updated,
        "[package]\nname = \"Foo\"\nversion = \"0.2.0\"\n\n[dependencies]\n\"Bar\" = \"0.1.0\"\n",
        "replaceVersionInToml: dependency entry with the same version string is untouched"
      )
    }
  }
}

test "replaceVersionInToml: version line at end of file (no trailing newline)" {
  val text = "[package]\nname = \"Foo\"\nversion = \"0.1.0\""
  match Cli.replaceVersionInToml(text, "0.1.0", "0.2.0") {
    case Err(e) -> panic("replaceVersionInToml: unexpected Err: " + e)
    case Ok(updated) -> {
      assertEqual(updated, "[package]\nname = \"Foo\"\nversion = \"0.2.0\"", "replaceVersionInToml: version at EOF")
    }
  }
}

test "replaceVersionInToml: version-not-found returns Err" {
  val text = "[package]\nname = \"Foo\"\nversion = \"0.1.0\"\n"
  match Cli.replaceVersionInToml(text, "9.9.9", "0.2.0") {
    case Ok(_) -> panic("replaceVersionInToml: expected Err when oldVersion does not match")
    case Err(_) -> ()
  }
}

test "replaceVersionInToml: missing [package] section returns Err" {
  val text = "[dependencies]\n\"Bar\" = \"0.1.0\"\n"
  match Cli.replaceVersionInToml(text, "0.1.0", "0.2.0") {
    case Ok(_) -> panic("replaceVersionInToml: expected Err when [package] is absent")
    case Err(_) -> ()
  }
}

test "replaceVersionInToml: trailing inline comment on the version line is preserved" {
  val text = "[package]\nname = \"Foo\"\nversion = \"0.1.0\" # pinned\n"
  match Cli.replaceVersionInToml(text, "0.1.0", "0.2.0") {
    case Err(e) -> panic("replaceVersionInToml: unexpected Err: " + e)
    case Ok(updated) -> {
      assertEqual(
        updated,
        "[package]\nname = \"Foo\"\nversion = \"0.2.0\" # pinned\n",
        "replaceVersionInToml: trailing inline comment preserved"
      )
    }
  }
}

test "replaceVersionInToml: CRLF line endings are preserved" {
  // #4731: replaceVersionInToml splits/rejoins on plain "\n", so each line
  // retains its own trailing "\r" — the split never separates the "\r" from
  // its line, so CRLF is preserved end to end without special-casing.
  val text = "[package]\r\nname = \"Foo\"\r\nversion = \"0.1.0\"\r\n"
  match Cli.replaceVersionInToml(text, "0.1.0", "0.2.0") {
    case Err(e) -> panic("replaceVersionInToml: unexpected Err: " + e)
    case Ok(updated) -> {
      assertEqual(
        updated,
        "[package]\r\nname = \"Foo\"\r\nversion = \"0.2.0\"\r\n",
        "replaceVersionInToml: CRLF endings preserved"
      )
    }
  }
}
