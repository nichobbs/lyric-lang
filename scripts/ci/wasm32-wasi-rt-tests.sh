#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# wasm32-wasi-rt-tests.sh — cross-compile lyric-rt for wasm32-wasi with a
# pinned wasi-sdk and run its C unit tests under a pinned wasmtime
# (docs/35 phase W2, D-progress-1028).
#
# Both toolchains are downloaded from their official GitHub releases and
# sha256-verified, then cached under $LYRIC_WASM_TOOLCACHE (default
# $RUNNER_TEMP/wasm-tools, falling back to a temp dir), so a persistent
# runner pays the download once.  wasi-sdk 24 ships clang 18, the same major
# version the native backend's other CI lanes pin.
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

WASI_SDK_VERSION="24"
WASI_SDK_SHA256="c6c38aab56e5de88adf6c1ebc9c3ae8da72f88ec2b656fb024eda8d4167a0bc5"
WASMTIME_VERSION="26.0.1"
WASMTIME_SHA256="5f3596cbe481422c32a4bc4505ad4db4fd15ed5eba5e6f0b359092b902f5269c"
WASM_TOOLS_VERSION="1.220.0"
WASM_TOOLS_SHA256="474a334c48d59ab5aed67381c287a53d1c5161adef8328fa0f9a7bdb8510e5f8"
WASI_ADAPTER_SHA256="5cf61fb9c5d5c47a63d2f61c4d8bfc3b2f862f7ed50e8d62c29c233597002af4"
JCO_VERSION="1.8.1"
PREVIEW2_SHIM_VERSION="0.17.1"

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

# jco transpiles the component for node; pinned alongside its preview2 shim.
jco_dir="$tools/jco-${JCO_VERSION}"
if [ ! -x "$jco_dir/node_modules/.bin/jco" ]; then
  mkdir -p "$jco_dir"
  (cd "$jco_dir" && npm init -y >/dev/null && \
    npm install --no-audit --no-fund "@bytecodealliance/jco@${JCO_VERSION}" "@bytecodealliance/preview2-shim@${PREVIEW2_SHIM_VERSION}" >/dev/null)
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
# The browser/JS-host `module` shape runs under node through its generated glue.
command -v node >/dev/null || { echo "::error::node not found on the runner"; exit 1; }
LYRIC_LOAD_COMPILER=1 "$lyric_bin" test lyric-compiler/lyric/llvm_wasm32_module_self_test.l
# The `component` shape: WIT + canonical ABI wrappers, componentized by wasm-tools
# and transpiled by jco to run under node.
WASM_TOOLS="$wt_dir/wasm-tools" LYRIC_WASI_ADAPTER="$adapter" \
  JCO="$jco_dir/node_modules/.bin/jco" LYRIC_JCO_NODE_MODULES="$jco_dir/node_modules" \
  LYRIC_LOAD_COMPILER=1 "$lyric_bin" test lyric-compiler/lyric/llvm_wasm32_component_self_test.l
