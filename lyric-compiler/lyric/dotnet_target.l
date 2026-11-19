//! dotnet_target.l — the .NET version that `--target dotnet` output is built for.
//!
//! `dotnetMajor` is the one place the compiler names that version.  The
//! target framework moniker, the framework version a `runtimeconfig.json`
//! asks for, the `lib/<tfm>/` directory of a published package, the default
//! `[nuget.options] target` and the Native AOT probe project all derive from
//! it.  It is the framework of the SDK that `bootstrap/global.json` pins;
//! `scripts/ci/check-dotnet-version.sh` fails the build when the two differ.
package Lyric.DotnetTarget

import Std.Core

/// Major version of the .NET release that emitted programs run on.
pub func dotnetMajor(): Int {
  10
}

/// Target framework moniker of emitted assemblies and packages ("net10.0").
pub func dotnetTfm(): String {
  "net" + toString(dotnetMajor()) + ".0"
}

/// Lowest `Microsoft.NETCore.App` version an emitted program accepts ("10.0.0").
pub func dotnetFrameworkVersion(): String {
  toString(dotnetMajor()) + ".0.0"
}

/// A framework-dependent `runtimeconfig.json`.  `extra` goes at the end of
/// the `runtimeOptions` object: an empty string for the minimal form, or a
/// comma-prefixed member such as `additionalProbingPaths`.
pub func runtimeConfigJson(extra: in String): String {
  "{\n" + "  \"runtimeOptions\": {\n" + "    \"tfm\": \"" + dotnetTfm() + "\",\n" + "    \"framework\": {\n" +
    "      \"name\": \"Microsoft.NETCore.App\",\n" +
    "      \"version\": \"" +
    dotnetFrameworkVersion() +
    "\"\n" +
    "    }" +
    extra +
    "\n" +
    "  }\n" +
    "}\n"
}
