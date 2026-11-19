# D622 - The toolchain and `--target dotnet` output move to .NET 11 (#9250)

**Status:** shipped.

## Context

The compiler was built with the .NET 10 SDK and every program it emitted for
`--target dotnet` asked for the .NET 10 runtime: `runtimeconfig.json` named
`net10.0` and `Microsoft.NETCore.App 10.0.0`, `lyric publish` packed into
`lib/net10.0/`, and the default `[nuget.options] target` was `net10.0`. On a
machine with only .NET 11 installed the compiler ran but nothing it built
would start.

The version used to be written in over a hundred places. #9242 reduced it to
three that a check keeps in step (`scripts/ci/check-dotnet-version.sh`): the
SDK in `bootstrap/global.json`, the ILCompiler reference of the entry point,
and `Lyric.DotnetTarget.dotnetMajor()` in the compiler.

## Decision

1. The toolchain is built with SDK 11.0.100 (`bootstrap/global.json`,
   `rollForward: disable` as before) and ILCompiler 11.0.0.
2. `--target dotnet` output targets .NET 11: `runtimeconfig.json` names
   `net11.0` and `Microsoft.NETCore.App 11.0.0`, `lyric publish` packs into
   `lib/net11.0/` with a `net11.0` dependency group, and the default
   `[nuget.options] target` is `net11.0`. A manifest that sets `target`
   keeps its value.
3. One .NET version is supported at a time. There is no flag or manifest key
   that selects the framework of emitted programs; `dotnetMajor()` is a
   compiler constant.
4. `--shape aot` passes ILCompiler and the linker what the .NET 11 SDK's own
   targets pass (`--stacktracedata:frames`, the
   `DotNetRuntimeContractDescriptor` export, the VxSort stub on arm64, zstd).
5. `Float.toByte()` and `Double.toByte()` truncate to `Int` and then wrap
   modulo 256 on every runtime version. The emitter used a bare `conv.u1`,
   whose result for a value outside 0..255 is unspecified and changed from
   wrapping to saturating in .NET 11.

## Consequences

- Users need the .NET 11 runtime to run `--target dotnet` programs and the
  .NET 11 SDK for `--shape aot`. A program built by an earlier release keeps
  running on .NET 10; rebuilding it with this release moves it to .NET 11.
- A package published by this release has only a `lib/net11.0/` asset, so a
  .NET 10 project cannot reference it.
- The bootstrap seed is a released compiler that still emits `net10.0`
  output until a release carries this change.

Progress: `docs/progress/2026-11-19-dotnet-11.md`.
