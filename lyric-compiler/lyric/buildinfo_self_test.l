//! buildinfo_self_test.l — runtime regression test for the Std.BuildInfo
//! accessor the compiler synthesizes into a file that imports Std.BuildInfo
//! (docs/60 §9.2).
//!
//! Importing `Std.BuildInfo` opts this module in, so the compiler appends a
//! `buildInfo()` accessor to it (the consumer-package synthesis pattern). This
//! test calls that accessor and asserts its runtime values. `lyric test`
//! threads no `--define`, so every value here is the deterministic
//! dev-checkout default:
//!
//!   version        = "0.0.0"   (no `version` define supplied)
//!   profile        = "debug"   (auto-injected build_profile for a non-release build)
//!   gitHash        = None      (reproducibility seam — supplied only on opt-in)
//!   buildTimestamp = None
//!   features       = []        (no active features under `lyric test`)
//!   target         = "dotnet" | "jvm" | "native"  (the build's own target)
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1`. Run in CI via native
//! `lyric test` on BOTH targets:
//!
//!   lyric test lyric-compiler/lyric/buildinfo_self_test.l
//!   lyric test --target jvm lyric-compiler/lyric/buildinfo_self_test.l
@test_module
package Lyric.BuildInfoSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Std.BuildInfo

func isKnownTarget(t: in String): Bool {
  t == "dotnet" or t == "jvm" or t == "native"
}

test "buildInfo() is synthesized and callable from a file that imports Std.BuildInfo" {
  val bi = buildInfo()
  assertTrue(isKnownTarget(bi.target), "target is the build's own target name")
}

test "version / profile take their deterministic dev-checkout fallbacks under lyric test" {
  val bi = buildInfo()
  assertEqual(bi.version, "0.0.0", "no version define supplied -> 0.0.0")
  assertEqual(bi.profile, "debug", "non-release build -> auto-injected build_profile=debug")
}

test "gitHash / buildTimestamp are None without their defines (reproducibility seam)" {
  val bi = buildInfo()
  match bi.gitHash {
    case Some(_) -> assertTrue(false, "gitHash must be None when no git_hash define is supplied")
    case None -> assertTrue(true, "gitHash None as expected")
  }
  match bi.buildTimestamp {
    case Some(_) -> assertTrue(false, "buildTimestamp must be None when no build_timestamp define is supplied")
    case None -> assertTrue(true, "buildTimestamp None as expected")
  }
}

test "features is empty when no features are active under lyric test" {
  val bi = buildInfo()
  assertEqualInt(bi.features.count, 0, "no active features -> empty list")
}

test "buildInfo() is stable across calls (pure synthesized accessor)" {
  val a = buildInfo()
  val b = buildInfo()
  assertEqual(a.version, b.version, "version stable")
  assertEqual(a.target, b.target, "target stable")
  assertEqual(a.profile, b.profile, "profile stable")
}
