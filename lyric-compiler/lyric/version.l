//! version.l — single source of truth for the compiler's own release version.
//!
//! The self-hosted compiler has no macro or build-flag mechanism to inject a
//! value into a `.l` source literal at compile time, so this reads it from
//! the environment instead: the AOT entry-point trampoline
//! (bootstrap/src/Lyric.Cli.Aot/Program.cs) sets LYRIC_BUILD_VERSION from a
//! compile-time C# constant baked from MSBuild's $(Version) property (see
//! the GenerateLyricBuildVersion target in Lyric.Cli.Aot.csproj) before
//! calling into this binary — so a released build (built with
//! `-p:Version=X.Y.Z`) reports its real version, while a dev checkout
//! (no override) falls back to "0.1.0" (docs/22 §5).
package Lyric.Version

import Std.Environment as Environment

pub func VERSION(): String {
  Environment.getVarOrDefault("LYRIC_BUILD_VERSION", "0.1.0")
}
