# The .NET version is chosen in `bootstrap/global.json`, and the compiler names its target framework once

The target framework of the `lyric` entry point was written out as `net10.0` in `bootstrap/Directory.Build.props`, in `Lyric.Cli.Aot.csproj`, in the `Makefile`, in `scripts/bootstrap.sh`, in 101 scripts under `scripts/ci/` and in four workflows (64 times in `ci.yml`), because the binary was built into `bin/<configuration>/net10.0/`. An SDK bump had to edit every one of them.

- `Lyric.Cli.Aot.csproj` reads its target framework from the SDK version in `bootstrap/global.json` (`10.0.404` gives `net10.0`), and its `System.Text.Json` reference follows it. It does not take the framework of the SDK running the build: `dotnet` started at the repository root does not see `bootstrap/global.json` and uses the newest installed SDK, which on the CI runners is .NET 11, and the Native AOT publish then fails against the pinned ILCompiler. `Directory.Build.props` no longer sets one.
- The project builds into `bin/<configuration>/` (`AppendTargetFrameworkToOutputPath` is off), so the binary is `bootstrap/src/Lyric.Cli.Aot/bin/<configuration>/lyric` and no path names a framework. Every script, workflow, the composite action and the `Makefile` use that path.
- `scripts/ci/plugin-sdk/csharp/DemoPlugin.csproj`, built and run in a temporary directory, targets the framework of the SDK that builds it, and `scripts/selfhost-check.sh` finds the reference pack of the framework `bootstrap/global.json` pins.

What still has to move with an SDK bump in the build is in `Lyric.Cli.Aot.csproj` beside the comment that explains it: the `Microsoft.DotNet.ILCompiler` version, which must be the one the pinned SDK ships.

## The framework of emitted programs

The compiler named the framework it targets (`net10.0`, framework version `10.0.0`) in six source files and 17 self-tests carried their own copy of the `runtimeconfig.json` text. `Lyric.DotnetTarget` (`lyric-compiler/lyric/dotnet_target.l`) now holds it: `dotnetMajor()` is the one literal, and `dotnetTfm()`, `dotnetFrameworkVersion()` and `runtimeConfigJson(extra)` derive from it. Its users are the `runtimeconfig.json` written beside a built program, the `lib/<tfm>/` directory, dependency group and project of `lyric publish`, the default `[nuget.options] target` in `lyric restore` and `Lyric.Pack`, the Native AOT probe project and the standalone-shape fallback in `Lyric.Release`, and the `System.Runtime` version `Msil.Lowering` falls back to. The self-tests call `runtimeConfigJson`. Output is unchanged: the value is still .NET 10.

The compiler cannot read `bootstrap/global.json`, so `scripts/ci/check-dotnet-version.sh` (a step of the `build` job) fails when `dotnetMajor()` or the ILCompiler reference names a different major version from the pinned SDK. A .NET bump is therefore three edits, with the check naming any that was missed: the SDK version in `global.json`, the ILCompiler version, and `dotnetMajor()`.

Verified on macOS: with SDK 11.0.100 at the repository root the project evaluates to `net10.0` and `dotnet publish -r osx-arm64` produces a working native `lyric`. With SDK 10.0.404: `make lyric` builds `bin/Release/lyric`, `make self-test NAME=manifest` passes (84 cases) and `scripts/ci/byte-println-e2e.sh dotnet` passes against the new path.

After the compiler change: `make lyric` rebuilds, a built program's `runtimeconfig.json` is byte-for-byte what it was, and the 17 self-tests that now call `runtimeConfigJson` pass, with `cli_publish`, `release` and `manifest`.
