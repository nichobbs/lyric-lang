# The build's .NET version is chosen in `bootstrap/global.json` alone

The target framework of the `lyric` entry point was written out as `net10.0` in `bootstrap/Directory.Build.props`, in `Lyric.Cli.Aot.csproj`, in the `Makefile`, in `scripts/bootstrap.sh`, in 101 scripts under `scripts/ci/` and in four workflows (64 times in `ci.yml`), because the binary was built into `bin/<configuration>/net10.0/`. An SDK bump had to edit every one of them.

- `Lyric.Cli.Aot.csproj` takes its target framework from the SDK that `bootstrap/global.json` pins (`net$(BundledNETCoreAppTargetFrameworkVersion)`), and its `System.Text.Json` reference follows it. `Directory.Build.props` no longer sets one.
- The project builds into `bin/<configuration>/` (`AppendTargetFrameworkToOutputPath` is off), so the binary is `bootstrap/src/Lyric.Cli.Aot/bin/<configuration>/lyric` and no path names a framework. Every script, workflow, the composite action and the `Makefile` use that path.
- `scripts/ci/plugin-sdk/csharp/DemoPlugin.csproj` follows the SDK the same way, and `scripts/selfhost-check.sh` takes the newest installed reference pack instead of the `net10.0` one.

What still has to move with an SDK bump is in `Lyric.Cli.Aot.csproj` beside the comment that explains it: the `Microsoft.DotNet.ILCompiler` version, which must be the one the pinned SDK ships.

The framework the compiler targets for the programs it emits (`runtimeconfig.json`, `lib/net10.0` in packages, the restore default) is a separate setting in the compiler sources and is unchanged here.

Verified on macOS with SDK 10.0.404: `make lyric` builds `bin/Release/lyric`, `make self-test NAME=manifest` passes (84 cases) and `scripts/ci/byte-println-e2e.sh dotnet` passes against the new path.
