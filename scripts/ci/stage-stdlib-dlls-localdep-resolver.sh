#!/usr/bin/env bash
set -euo pipefail
if [ ! -d .bootstrap/stage1 ] || [ ! -f .bootstrap/stage1/Lyric.Lyric.Cli.dll ]; then
  echo "::error::stage 1 bundle missing; ecosystem tests cannot run"
  exit 1
fi
if [ ! -x "$LYRIC_CLI_PATH" ]; then
  echo "::error::AOT binary not found at $LYRIC_CLI_PATH"
  exit 1
fi
# Stage 1 compiled all Lyric.Stdlib*.dll files into .bootstrap/stage1/.
# Copy them all to the canonical dep-resolution path so the test runner's
# local-path dep resolver finds it without re-running a manifest build.
# The main bundle (Lyric.Stdlib.dll) is required for compile-time dep
# resolution; the individual DLLs (e.g. Lyric.Stdlib.Testing.dll) are
# needed at runtime by compiled test DLLs.
shopt -s nullglob
stdlib_dlls=(.bootstrap/stage1/Lyric.Stdlib*.dll)
shopt -u nullglob
if (( ${#stdlib_dlls[@]} == 0 )); then
  echo "::error::no Lyric.Stdlib*.dll found in .bootstrap/stage1"
  exit 1
fi
mkdir -p lyric-stdlib/bin
cp "${stdlib_dlls[@]}" lyric-stdlib/bin/
# lyric-session no longer needs a host shim: Session.Kernel.Net
# binds StackExchange.Redis directly via @externTarget in native
# Lyric (#1777). lyric-auth likewise needs no shim (pure Lyric
# HMAC-SHA256 + constant-time comparison).
# Route emitProject subprocess calls to the F# bootstrap CLI, which
# handles --internal-project-build.  The AOT binary is a pure trampoline
# into the Lyric CLI dispatcher and does not handle internal flags
# (#1082 stripped the AOT entry point of its path-discovery shim).
# Written to $GITHUB_ENV (not `export`) so it also applies to the
# later "Build path dependencies" / "Run tests" steps in this job.
cli_dll="$(pwd)/bootstrap/src/Lyric.Cli/bin/${BUILD_CONFIG}/net10.0/lyric.dll"
if [ -f "$cli_dll" ]; then
  echo "LYRIC_BIN=dotnet" >> "$GITHUB_ENV"
  echo "LYRIC_CLI_DLL=$cli_dll" >> "$GITHUB_ENV"
fi

