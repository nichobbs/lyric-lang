#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# fetch-wasm-toolchain.sh — the pinned wasm32 toolchain, for sourcing.
#
#   source scripts/ci/fetch-wasm-toolchain.sh
#
# Downloads (once, into $LYRIC_WASM_TOOLCACHE, default $RUNNER_TEMP/wasm-tools
# or a temporary directory) and sha256-verifies:
#   - wasi-sdk          -> $LYRIC_WASI_SDK_DIR
#   - wasm-tools        -> $LYRIC_WASM_TOOLS_BIN
#   - the preview1 reactor adapter (from wasmtime's release)
#                       -> $LYRIC_WASI_ADAPTER_FILE
# and sets $LYRIC_WASM_TOOLCACHE to the cache directory.  These are the tools
# a `--triple wasm32-wasi` build needs, and the component shape's
# componentization (docs/35).  scripts/ci/wasm32-wasi-rt-tests.sh and
# scripts/ci/plugin-component-e2e.sh share the pins through this file.
# ---------------------------------------------------------------------------

WASI_SDK_VERSION="34"
WASI_SDK_SHA256="b761e3a0721dbae9c09a0059e5fdb2bf917d1b4a8a7b430fb3b5aafb0984b2c4"
WASM_TOOLS_VERSION="1.262.0"
WASM_TOOLS_SHA256="655b8df67d54c3ef9b52fc237c4e94bbfbb5f5f43825245cb0940a7002a9ed65"
WASI_ADAPTER_WASMTIME_VERSION="49.0.3"
WASI_ADAPTER_SHA256="79fa20ff8d49f1aba13d25af4fd616a1431028fff954b2927e55fcac4fefd6e3"

LYRIC_WASM_TOOLCACHE="${LYRIC_WASM_TOOLCACHE:-${RUNNER_TEMP:-$(mktemp -d)}/wasm-tools}"
mkdir -p "$LYRIC_WASM_TOOLCACHE"

lyric_wasm_fetch() { # url sha256 dest
  if [ ! -f "$3" ]; then
    curl -fsSL "$1" -o "$3.part"
    echo "$2  $3.part" | sha256sum -c - >&2
    mv "$3.part" "$3"
  fi
}

LYRIC_WASI_SDK_DIR="$LYRIC_WASM_TOOLCACHE/wasi-sdk-${WASI_SDK_VERSION}.0-x86_64-linux"
if [ ! -d "$LYRIC_WASI_SDK_DIR" ]; then
  lyric_wasm_fetch "https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-${WASI_SDK_VERSION}/wasi-sdk-${WASI_SDK_VERSION}.0-x86_64-linux.tar.gz" \
    "$WASI_SDK_SHA256" "$LYRIC_WASM_TOOLCACHE/wasi-sdk.tar.gz"
  tar -xzf "$LYRIC_WASM_TOOLCACHE/wasi-sdk.tar.gz" -C "$LYRIC_WASM_TOOLCACHE"
fi

lyric_wasm_tools_dir="$LYRIC_WASM_TOOLCACHE/wasm-tools-${WASM_TOOLS_VERSION}-x86_64-linux"
if [ ! -d "$lyric_wasm_tools_dir" ]; then
  lyric_wasm_fetch "https://github.com/bytecodealliance/wasm-tools/releases/download/v${WASM_TOOLS_VERSION}/wasm-tools-${WASM_TOOLS_VERSION}-x86_64-linux.tar.gz" \
    "$WASM_TOOLS_SHA256" "$LYRIC_WASM_TOOLCACHE/wasm-tools.tar.gz"
  tar -xzf "$LYRIC_WASM_TOOLCACHE/wasm-tools.tar.gz" -C "$LYRIC_WASM_TOOLCACHE"
fi
LYRIC_WASM_TOOLS_BIN="$lyric_wasm_tools_dir/wasm-tools"

LYRIC_WASI_ADAPTER_FILE="$LYRIC_WASM_TOOLCACHE/wasi_snapshot_preview1.reactor.wasm"
lyric_wasm_fetch "https://github.com/bytecodealliance/wasmtime/releases/download/v${WASI_ADAPTER_WASMTIME_VERSION}/wasi_snapshot_preview1.reactor.wasm" \
  "$WASI_ADAPTER_SHA256" "$LYRIC_WASI_ADAPTER_FILE"

export LYRIC_WASM_TOOLCACHE LYRIC_WASI_SDK_DIR LYRIC_WASM_TOOLS_BIN LYRIC_WASI_ADAPTER_FILE
