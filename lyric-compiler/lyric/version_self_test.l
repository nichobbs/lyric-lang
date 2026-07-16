//! version_self_test.l — exercises `Lyric.Version.VERSION()` (version.l):
//! asserts it always returns a valid semver, and that the dev-checkout
//! default ("0.1.0", used when LYRIC_BUILD_VERSION is unset) is exactly
//! what a self-test run (no release override) should observe (docs/22 §5).
//!
//! Run in CI via:
//!
//!   lyric test lyric-compiler/lyric/version_self_test.l
@test_module
package Lyric.VersionSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Lyric.Version as Ver
import Lyric.Cli as Cli

test "VERSION() is a valid semver" {
  assertEqual(Cli.validateSemver(Ver.VERSION()), "", "Lyric.Version.VERSION() must be a valid semver")
}

test "VERSION() falls back to the dev placeholder when LYRIC_BUILD_VERSION is unset" {
  assertEqual(Ver.VERSION(), "0.1.0", "self-test runs carry no release override")
}
