#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# wasm32-wasi-rt-tests.sh — cross-compile lyric-rt for wasm32-wasi with a
# pinned wasi-sdk and run its C unit tests under a pinned wasmtime
# (docs/35 phase W2, D-progress-1028).
#
# Both toolchains are downloaded from their official GitHub releases and
# sha256-verified, then cached under $WASM_TOOLS (default
# $RUNNER_TEMP/wasm-tools, falling back to a temp dir), so a persistent
# runner pays the download once.  wasi-sdk 24 ships clang 18, the same major
# version the native backend's other CI lanes pin.
#
# Usage: bash scripts/ci/wasm32-wasi-rt-tests.sh
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

WASI_SDK_VERSION="24"
WASI_SDK_SHA256="c6c38aab56e5de88adf6c1ebc9c3ae8da72f88ec2b656fb024eda8d4167a0bc5"
WASMTIME_VERSION="26.0.1"
WASMTIME_SHA256="5f3596cbe481422c32a4bc4505ad4db4fd15ed5eba5e6f0b359092b902f5269c"

tools="${WASM_TOOLS:-${RUNNER_TEMP:-$(mktemp -d)}/wasm-tools}"
mkdir -p "$tools"

fetch() { # url sha256 dest-tarball
  if [ ! -f "$3" ]; then
    curl -fsSL "$1" -o "$3.part"
    echo "$2  $3.part" | sha256sum -c -
    mv "$3.part" "$3"
  fi
}

wasi_dir="$tools/wasi-sdk-${WASI_SDK_VERSION}.0-x86_64-linux"
if [ ! -d "$wasi_dir" ]; then
  fetch "https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-${WASI_SDK_VERSION}/wasi-sdk-${WASI_SDK_VERSION}.0-x86_64-linux.tar.gz" \
    "$WASI_SDK_SHA256" "$tools/wasi-sdk.tar.gz"
  tar -xzf "$tools/wasi-sdk.tar.gz" -C "$tools"
fi

wasmtime_dir="$tools/wasmtime-v${WASMTIME_VERSION}-x86_64-linux"
if [ ! -d "$wasmtime_dir" ]; then
  fetch "https://github.com/bytecodealliance/wasmtime/releases/download/v${WASMTIME_VERSION}/wasmtime-v${WASMTIME_VERSION}-x86_64-linux.tar.xz" \
    "$WASMTIME_SHA256" "$tools/wasmtime.tar.xz"
  tar -xJf "$tools/wasmtime.tar.xz" -C "$tools"
fi

make -C lyric-rt test-wasm32-wasi WASI_SDK="$wasi_dir" WASMTIME="$wasmtime_dir/wasmtime"

BUILD_CONFIG="${BUILD_CONFIG:-Debug}"
lyric_bin="bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin; cannot run the wasm32 self-test"
  exit 1
fi
export WASI_SDK_PATH="$wasi_dir" WASMTIME="$wasmtime_dir/wasmtime"
LYRIC_LOAD_COMPILER=1 "$lyric_bin" test lyric-compiler/lyric/llvm_wasm32_self_test.l
