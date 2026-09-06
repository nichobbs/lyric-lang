#!/usr/bin/env bash
set -euo pipefail
if [ ! -d .bootstrap/stage1 ] || [ ! -f .bootstrap/stage1/Lyric.Lyric.Cli.dll ]; then
  echo "::error::stage 1 bundle missing; ecosystem library builds cannot run"
  exit 1
fi
lyric_bin="bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin"
  exit 1
fi
# Ensure stdlib DLLs are in the canonical dep-resolution path.
shopt -s nullglob
stdlib_dlls=(.bootstrap/stage1/Lyric.Stdlib*.dll)
shopt -u nullglob
if (( ${#stdlib_dlls[@]} == 0 )); then
  echo "::error::no Lyric.Stdlib*.dll found in .bootstrap/stage1"
  exit 1
fi
mkdir -p lyric-stdlib/bin
cp "${stdlib_dlls[@]}" lyric-stdlib/bin/
# Route emitProject subprocess hops to the F# bootstrap CLI.
cli_dll="$(pwd)/bootstrap/src/Lyric.Cli/bin/${BUILD_CONFIG}/net10.0/lyric.dll"
if [ -f "$cli_dll" ]; then
  export LYRIC_BIN=dotnet
  export LYRIC_CLI_DLL="$cli_dll"
fi
# Tier 0: libraries with no local path dependencies.
tier0=(
  lyric-cache lyric-logging lyric-proto lyric-generator-sdk
  lyric-mail lyric-storage lyric-auth lyric-resilience
  lyric-validation lyric-i18n lyric-otel lyric-feature-flags
  lyric-aws-xray lyric-aws-secrets lyric-db lyric-jsonrpc
)
for lib in "${tier0[@]}"; do
  echo "=== build $lib (tier 0) ==="
  if ! "$lyric_bin" build --manifest "$lib/lyric.toml"; then
    echo "::error::$lib (tier 0) failed to build"
    exit 1
  fi
done
# Tier 1: libraries depending only on tier-0 libraries.
tier1=(lyric-mq lyric-session lyric-jobs lyric-search lyric-ws lyric-web lyric-grpc lyric-mcp)
for lib in "${tier1[@]}"; do
  echo "=== build $lib (tier 1) ==="
  if ! "$lyric_bin" build --manifest "$lib/lyric.toml"; then
    echo "::error::$lib (tier 1) failed to build"
    exit 1
  fi
done
# Tier 2: libraries depending on tier-0 and tier-1 libraries.
tier2=(lyric-health lyric-testing lyric-lambda)
for lib in "${tier2[@]}"; do
  echo "=== build $lib (tier 2) ==="
  if ! "$lyric_bin" build --manifest "$lib/lyric.toml"; then
    echo "::error::$lib (tier 2) failed to build"
    exit 1
  fi
done
echo "all ecosystem libraries built"

