//! std/buildinfo.l — the standardized build-metadata surface (docs/60 §9.2).
//!
//! `BuildInfo` is the curated layer over raw build defines (docs/60 §5): one
//! blessed record carrying version / target / profile / feature metadata that
//! a program reads instead of hand-declaring `@build_const` constants. This is
//! the Lyric analog of Go's `runtime/debug.ReadBuildInfo()` — the *toolchain*
//! provides the values; you don't declare them.
//!
//! The TYPE lives here in stdlib (a type carries no per-build value, so it is
//! safe to share). The VALUES are per-build and therefore never baked here:
//! the compiler synthesizes a `buildInfo()` accessor into the *consumer's own
//! root package* (docs/60 §9.2 — the AST-synthesis pattern `test_synth.l` and
//! `stubbable.l` already use), so each program reports *its own* resolved
//! defines, not the stdlib's. Import this module and call `buildInfo()`:
//!
//!   import Std.BuildInfo
//!
//!   func startupBanner(): String {
//!     val bi = buildInfo()
//!     "myapp " + bi.version + " (" + bi.target + "/" + bi.profile + ")"
//!   }
//!
//! `version` / `target` / `profile` are deterministic functions of the build
//! configuration (docs/60 §8), so they are always-present `String`s. `gitHash`
//! and `buildTimestamp` are *not* pure functions of the config — baking them by
//! default would break the three-stage byte-compare — so they are
//! `Option[String]`, `None` unless the build explicitly supplies the
//! `git_hash` / `build_timestamp` defines (docs/60 §9.2). `features` is the
//! active feature set, unifying docs/24 Q-features-003.
package Std.BuildInfo

import Std.Core
import Std.Collections

// `@experimental` while the value-population half of the feature is still
// in flight: the well-known-define auto-injection that fills `version` /
// `profile` on every build (not only on the single-file dotnet `--define`
// path) is deferred to #5852 (docs/60 §9.2). The record shape is not expected
// to change, but per the docs/10-stdlib-plan.md cut convention a surface with
// known pre-stabilization follow-up ships `@experimental` until it lands.
@experimental
pub record BuildInfo {
  version: String          // always present — deterministic (docs/60 §3.3)
  target: String          // "dotnet" | "jvm" | "native"
  profile: String          // "debug" | "release"
  gitHash: Option[String]  // None unless the git_hash define is supplied
  buildTimestamp: Option[String]  // None unless the build_timestamp define is supplied
  features: List[String]    // active feature set (docs/24 Q-features-003)
}
