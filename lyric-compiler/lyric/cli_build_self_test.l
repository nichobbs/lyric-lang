//! cli_build_self_test.l — exercises the pure `--package-version` validator
//! in `Lyric.Cli` (cli/cli_build.l): `validatePackageVersionArg` (#4426,
//! #4727). No I/O — safe to run without a manifest, network, or toolchain.
//!
//! Run in CI via:
//!
//!   lyric test lyric-compiler/lyric/cli_build_self_test.l
@test_module
package Lyric.CliBuildSelfTest

import Std.Core
import Std.String as Str
import Std.Testing
import Lyric.Cli as Cli

test "validatePackageVersionArg: empty string is rejected" {
  match Cli.validatePackageVersionArg("") {
    case None -> assertTrue(false, "empty string should be rejected")
    case Some(msg) -> assertTrue(Str.contains(msg, "non-empty"), "empty-string message mentions non-empty")
  }
}

test "validatePackageVersionArg: whitespace-only string is rejected" {
  match Cli.validatePackageVersionArg("   ") {
    case None -> assertTrue(false, "whitespace-only string should be rejected")
    case Some(msg) -> assertTrue(Str.contains(msg, "non-empty"), "whitespace-only message mentions non-empty")
  }
}

test "validatePackageVersionArg: lowercase v-prefix is rejected" {
  match Cli.validatePackageVersionArg("v1.0.0") {
    case None -> assertTrue(false, "'v1.0.0' should be rejected")
    case Some(msg) -> assertTrue(Str.contains(msg, "1.0.0"), "v-prefix message includes the stripped suggestion")
  }
}

test "validatePackageVersionArg: uppercase V-prefix is rejected" {
  match Cli.validatePackageVersionArg("V2.0.0") {
    case None -> assertTrue(false, "'V2.0.0' should be rejected")
    case Some(msg) -> assertTrue(Str.contains(msg, "2.0.0"), "V-prefix message includes the stripped suggestion")
  }
}

test "validatePackageVersionArg: plain semver is accepted" {
  match Cli.validatePackageVersionArg("1.0.0") {
    case None -> ()
    case Some(msg) -> assertTrue(false, "'1.0.0' should be accepted, got: " + msg)
  }
}

test "validatePackageVersionArg: bare 'v' (length 1, no digit to check) is accepted" {
  match Cli.validatePackageVersionArg("v") {
    case None -> ()
    case Some(msg) -> assertTrue(false, "'v' alone should be accepted, got: " + msg)
  }
}

test "validatePackageVersionArg: 'v' followed by a non-digit is accepted" {
  // Guards against false positives on words that merely start with 'v' —
  // only a v/V immediately followed by an ASCII digit is a git-tag prefix.
  match Cli.validatePackageVersionArg("vendor1.0") {
    case None -> ()
    case Some(msg) -> assertTrue(false, "'vendor1.0' should be accepted, got: " + msg)
  }
}
