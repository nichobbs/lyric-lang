#!/usr/bin/env bash
set -euo pipefail
if [ ! -d .bootstrap/stage1 ] || [ ! -f .bootstrap/stage1/Lyric.Lyric.Cli.dll ]; then
  echo "::error::stage 1 bundle missing; example package build cannot run"
  exit 1
fi
lyric_bin="bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin"
  exit 1
fi
# The self-hosted MSIL bridge resolves `import Std.X` from
# lyric-stdlib/std/*.l source, but each manifest also lists
# Lyric.Stdlib as a path dependency whose output DLL must exist;
# stage 1 already compiled it into .bootstrap/stage1/.
shopt -s nullglob
stdlib_dlls=(.bootstrap/stage1/Lyric.Stdlib*.dll)
shopt -u nullglob
if (( ${#stdlib_dlls[@]} == 0 )); then
  echo "::error::no Lyric.Stdlib*.dll found in .bootstrap/stage1"
  exit 1
fi
mkdir -p lyric-stdlib/bin
cp "${stdlib_dlls[@]}" lyric-stdlib/bin/
# Route emitProject subprocess hops to the F# bootstrap CLI (the
# AOT binary is a pure trampoline; same wiring as the steps above).
cli_dll="$(pwd)/bootstrap/src/Lyric.Cli/bin/${BUILD_CONFIG}/net10.0/lyric.dll"
if [ -f "$cli_dll" ]; then
  export LYRIC_BIN=dotnet
  export LYRIC_CLI_DLL="$cli_dll"
fi
# Build the dependency libraries bottom-up so each example's
# restored path deps resolve to an existing bin/<assembly>.dll.
# lyric-otel/lyric-db/lyric-web's plain `build` auto-resolves their
# own NuGet deps here (their manifests hit `lyric build`'s
# lyric.lock-missing auto-restore path). lyric-grpc's does not --
# confirmed on a real run (#6582) that its build fails here the
# same way it does everywhere else without an explicit restore
# first, so give it the same treatment as the "Test multi-package
# examples" / dedicated "Run tests (grpc)" steps.
libs=(lyric-logging lyric-auth lyric-resilience lyric-otel lyric-db lyric-web lyric-health lyric-grpc)
for lib in "${libs[@]}"; do
  if [ "$lib" = "lyric-grpc" ]; then
    echo "=== restore dependency $lib ==="
    if ! "$lyric_bin" restore --manifest "$lib/lyric.toml"; then
      echo "::error::failed to restore $lib NuGet dependencies"
      exit 1
    fi
  fi
  echo "=== build dependency $lib ==="
  if ! "$lyric_bin" build --manifest "$lib/lyric.toml"; then
    echo "::error::failed to build example dependency $lib"
    exit 1
  fi
done
# Build each example package end-to-end.
examples=(rbac ledger jobqueue product-catalog)
for ex in "${examples[@]}"; do
  echo "=== build example $ex ==="
  if ! "$lyric_bin" build --manifest "examples/$ex/lyric.toml"; then
    echo "::error::example package $ex failed to build"
    exit 1
  fi
done
echo "all example packages built"

