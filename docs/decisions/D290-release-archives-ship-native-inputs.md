# D290 - Release archives ship the native target's inputs (#8454)

**Status:** shipped

## Context

`--target native` compiles `lyric-stdlib/std/**/*.l` from source and links
`lyric_rt.a`. No archive held either, so an installed `lyric` could build native
programs only with `LYRIC_STD_PATH` and `LYRIC_RT_PATH` pointing into a checkout.

## Decision

1. Every archive stages `lib/std/` (the contents of `lyric-stdlib/std/`) and the
   runtime built for the archive's architecture: `lib/lyric_rt.a` (linux-x64 and
   osx-arm64 natively, linux-arm64 with `aarch64-linux-gnu-gcc`, osx-x64 with
   `clang -arch x86_64`); `lib/lyric_rt-x86_64-pc-windows-msvc.lib` and
   `lib/lyric_rt_md-x86_64-pc-windows-msvc.lib` on win-x64 (CMake, Ninja, clang).
2. `findStdlibSourcesNativeForShape` looks at `<binary dir>/lib/std` after
   `$LYRIC_STD_PATH` and before the walk-ups (`installedStdlibSourceDir`). Only the
   native loader reads it; dotnet and JVM keep the compiled bundle.
   `findLyricRtArchive` already read `<binary dir>/lib`.
3. `scripts/ci/release-native-smoke.sh` unpacks an archive outside the checkout
   and builds and runs a native hello-world with neither variable set. It runs for
   each runnable tar.gz in the release job and on the Windows archive before the
   Windows native suite. `windows-native-e2e.sh` no longer sets `LYRIC_STD_PATH`.

## Limits

The NuGet global tool ships neither input. linux-arm64 is built but not run (no
arm64 runner), so its archive is checked for the files only by the packaging
steps.
