#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# wasm32-wasi-rt-tests.sh — cross-compile lyric-rt for wasm32-wasi with a
# pinned wasi-sdk and run its C unit tests under a pinned wasmtime
# (docs/35 phase W2, D-progress-1028).
#
# Both toolchains are downloaded from their official GitHub releases and
# sha256-verified, then cached under $LYRIC_WASM_TOOLCACHE (default
# $RUNNER_TEMP/wasm-tools, falling back to a temp dir), so a persistent
# runner pays the download once.  wasi-sdk 34 ships clang 23, newer than the
# clang 18 the native backend's other CI lanes pin, so this lane also checks
# that the emitted IR stays valid across that range.
#
# It also checks the embedded JS glue is current, runs the module-shape
# self-test under node, and runs scripts/audit-native-extern-abi.sh, which fails
# when a kernel extern disagrees with the runtime definition it binds on the
# wasm32 ABI.
#
# Usage: bash scripts/ci/wasm32-wasi-rt-tests.sh
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

WASI_SDK_VERSION="34"
WASI_SDK_SHA256="b761e3a0721dbae9c09a0059e5fdb2bf917d1b4a8a7b430fb3b5aafb0984b2c4"
WASMTIME_VERSION="49.0.3"
WASMTIME_SHA256="4001225413f208345b980525f31c4080e1873808b38d0ddc7918497340667fbb"
WASM_TOOLS_VERSION="1.262.0"
WASM_TOOLS_SHA256="655b8df67d54c3ef9b52fc237c4e94bbfbb5f5f43825245cb0940a7002a9ed65"
WASI_ADAPTER_SHA256="79fa20ff8d49f1aba13d25af4fd616a1431028fff954b2927e55fcac4fefd6e3"
JCO_VERSION="1.39.0"
PREVIEW2_SHIM_VERSION="0.30.0"
PREVIEW3_SHIM_VERSION="0.11.0"
# jco's output for a Component Model async export calls WebAssembly.promising,
# which node ships from 24 (D184); the component suite runs it under this node.
# wac composes a test consumer with a component, so the component suite can make
# concurrent calls into one instance under wasmtime (D184 slice A3).
WAC_VERSION="0.12.0"
WAC_SHA256="7cd490edbd452221ef89e6750fc43eacc9b71b1242095eb577cb9a3bf0d3beda"
NODE_VERSION="24.22.0"
NODE_SHA256="cc2f601cee82d9a5a233302fe307abc600727035fd7d2c3a3571755989e95008"

tools="${LYRIC_WASM_TOOLCACHE:-${RUNNER_TEMP:-$(mktemp -d)}/wasm-tools}"
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

wt_dir="$tools/wasm-tools-${WASM_TOOLS_VERSION}-x86_64-linux"
if [ ! -d "$wt_dir" ]; then
  fetch "https://github.com/bytecodealliance/wasm-tools/releases/download/v${WASM_TOOLS_VERSION}/wasm-tools-${WASM_TOOLS_VERSION}-x86_64-linux.tar.gz" \
    "$WASM_TOOLS_SHA256" "$tools/wasm-tools.tar.gz"
  tar -xzf "$tools/wasm-tools.tar.gz" -C "$tools"
fi

# The preview1 reactor adapter ships with wasmtime's releases.
adapter="$tools/wasi_snapshot_preview1.reactor.wasm"
fetch "https://github.com/bytecodealliance/wasmtime/releases/download/v${WASMTIME_VERSION}/wasi_snapshot_preview1.reactor.wasm" \
  "$WASI_ADAPTER_SHA256" "$adapter"

# jco transpiles the component for node; pinned alongside its WASI shims (the
# preview3 shim backs the WASI 0.3 clock an async component waits on).
jco_dir="$tools/jco-${JCO_VERSION}-p3-${PREVIEW3_SHIM_VERSION}"
if [ ! -x "$jco_dir/node_modules/.bin/jco" ]; then
  mkdir -p "$jco_dir"
  (cd "$jco_dir" && npm init -y >/dev/null && \
    npm install --no-audit --no-fund "@bytecodealliance/jco@${JCO_VERSION}" \
      "@bytecodealliance/preview2-shim@${PREVIEW2_SHIM_VERSION}" \
      "@bytecodealliance/preview3-shim@${PREVIEW3_SHIM_VERSION}" >/dev/null)
fi

wac="$tools/wac-${WAC_VERSION}"
fetch "https://github.com/bytecodealliance/wac/releases/download/v${WAC_VERSION}/wac-cli-x86_64-unknown-linux-musl" \
  "$WAC_SHA256" "$wac"
chmod +x "$wac"

node_dir="$tools/node-v${NODE_VERSION}-linux-x64"
if [ ! -x "$node_dir/bin/node" ]; then
  fetch "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
    "$NODE_SHA256" "$tools/node.tar.xz"
  tar -xJf "$tools/node.tar.xz" -C "$tools"
fi

# The module-shape JS glue is embedded in the compiler from a real .js file.
python3 scripts/gen_wasm_glue.py --check

# Every _kernel_native extern must match the C ABI it binds (docs/35 W2 slice 3).
WASI_SDK_PATH="$wasi_dir" bash scripts/audit-native-extern-abi.sh

make -C lyric-rt test-wasm32-wasi WASI_SDK="$wasi_dir" WASMTIME="$wasmtime_dir/wasmtime"

BUILD_CONFIG="${BUILD_CONFIG:-Debug}"
lyric_bin="bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin; cannot run the wasm32 self-test"
  exit 1
fi
export WASI_SDK_PATH="$wasi_dir" WASMTIME="$wasmtime_dir/wasmtime"
export LYRIC_RT_WASM32_PATH="$PWD/lyric-rt/build-wasm32-wasi/lyric_rt.a"
LYRIC_LOAD_COMPILER=1 "$lyric_bin" test lyric-compiler/lyric/llvm_wasm32_self_test.l
# The in-memory WASI filesystem behind the module shape's preopened root (no toolchain needed).
node --test lyric-compiler/lyric/wasm/memfs_test.mjs
# The browser/JS-host `module` shape runs under node through its generated glue.
command -v node >/dev/null || { echo "::error::node not found on the runner"; exit 1; }
LYRIC_LOAD_COMPILER=1 "$lyric_bin" test lyric-compiler/lyric/llvm_wasm32_module_self_test.l
# The `[npm]` checks of a wasm32 project build, through the CLI entry point (needs npm).
LYRIC_LOAD_COMPILER=1 "$lyric_bin" test lyric-compiler/lyric/cli_wasm_npm_project_self_test.l
# The `component` shape: WIT + canonical ABI wrappers, componentized by wasm-tools
# and transpiled by jco to run under node.
WASM_TOOLS="$wt_dir/wasm-tools" LYRIC_WASI_ADAPTER="$adapter" NODE="$node_dir/bin/node" WAC="$wac" \
  JCO="$jco_dir/node_modules/.bin/jco" LYRIC_JCO_NODE_MODULES="$jco_dir/node_modules" \
  LYRIC_LOAD_COMPILER=1 "$lyric_bin" test lyric-compiler/lyric/llvm_wasm32_component_self_test.l
# A plugin built as a wasm32-wasi module and run under wasmtime by a dotnet host (D207 Decision 6).
LYRIC_WASMTIME="$wasmtime_dir/wasmtime" bash scripts/ci/plugin-e2e.sh "$lyric_bin" dotnet wasm
