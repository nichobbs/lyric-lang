#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# plugin-component-e2e.sh — run lyric-stdlib/tests/plugin_component_e2e_tests.l:
# a component plugin hosted in-process by Std.PluginWasm (docs/69 §9.3).
#
# Usage: plugin-component-e2e.sh <lyric-binary> <host-target>...
#
#   host-target  dotnet | jvm | native  (one or more)
#
# Builds lyric-stdlib/tests/plugin_fixtures/greeter_component.l as a wasm32
# component into a fresh plugin directory, the in-process embedding
# (`make -C lyric-rt wasmhost`, and lyric_rt.a for a native host), and fetches
# the pinned wasmtime C API (scripts/ci/fetch-wasmtime-capi.sh).  Each host
# then runs the suite twice: with libwasmtime available
# ($LYRIC_WASMTIME_LIB), and with it deliberately missing, where only the
# fallback is checked.  dotnet and JVM hosts load the embedding's library
# from $LYRIC_WASMHOST_LIB.
#
# The component build needs the wasm32 toolchain: $WASI_SDK_PATH,
# $LYRIC_RT_WASM32_PATH, $WASM_TOOLS and $LYRIC_WASI_ADAPTER.  When they are
# unset, scripts/ci/fetch-wasm-toolchain.sh fetches the pinned wasi-sdk,
# wasm-tools and preview1 adapter, and lyric-rt is cross-built for wasm32.
# The JVM host needs a JDK 22 or later `java` on PATH (D158, D229).
# ---------------------------------------------------------------------------
set -euo pipefail

usage="usage: plugin-component-e2e.sh <lyric-binary> <dotnet|jvm|native>..."
LYRIC_BIN="${1:?$usage}"
shift
[ "$#" -gt 0 ] || { echo "$usage" >&2; exit 2; }
for target in "$@"; do
  case "$target" in
    dotnet|jvm|native) ;;
    *) echo "$usage" >&2; exit 2 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
case "$LYRIC_BIN" in
  /*) ;;
  *) LYRIC_BIN="$REPO_ROOT/$LYRIC_BIN" ;;
esac

if [ -z "${WASI_SDK_PATH:-}" ] || [ -z "${WASM_TOOLS:-}" ] || [ -z "${LYRIC_WASI_ADAPTER:-}" ]; then
  # shellcheck source=scripts/ci/fetch-wasm-toolchain.sh
  source scripts/ci/fetch-wasm-toolchain.sh
  export WASI_SDK_PATH="$LYRIC_WASI_SDK_DIR" WASM_TOOLS="$LYRIC_WASM_TOOLS_BIN" LYRIC_WASI_ADAPTER="$LYRIC_WASI_ADAPTER_FILE"
fi
if [ -z "${LYRIC_RT_WASM32_PATH:-}" ]; then
  make -C lyric-rt wasm32-wasi WASI_SDK="$WASI_SDK_PATH" >/dev/null
  export LYRIC_RT_WASM32_PATH="$REPO_ROOT/lyric-rt/build-wasm32-wasi/lyric_rt.a"
fi

capi="$(bash scripts/ci/fetch-wasmtime-capi.sh)"
make -C lyric-rt wasmhost >/dev/null
case "$(uname -s)" in
  Darwin) ext=dylib ;;
  *) ext=so ;;
esac
wasmhost_lib="$REPO_ROOT/lyric-rt/build/liblyric_wasmhost.$ext"
wasmtime_lib="$capi/lib/libwasmtime.$ext"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
plugin_dir="$work/plugins/greeter-component"
mkdir -p "$plugin_dir"
"$LYRIC_BIN" build lyric-stdlib/tests/plugin_fixtures/greeter_component.l \
  --target native --triple wasm32-wasi --shape component -o "$plugin_dir/greeter.wasm"

for target in "$@"; do
  if [ "$target" = native ]; then
    make -C lyric-rt >/dev/null
  fi
  echo "=== plugin_component_e2e_tests.l (--target $target, libwasmtime available) ==="
  LYRIC_PLUGIN_COMPONENT_DIR="$plugin_dir" \
  LYRIC_PLUGIN_COMPONENT_FILE="greeter.wasm" \
  LYRIC_PLUGIN_COMPONENT_EXPECT=available \
  LYRIC_WASMHOST_LIB="$wasmhost_lib" \
  LYRIC_WASMTIME_LIB="$wasmtime_lib" \
    "$LYRIC_BIN" test --target "$target" lyric-stdlib/tests/plugin_component_e2e_tests.l
  echo "=== plugin_component_e2e_tests.l (--target $target, libwasmtime missing) ==="
  LYRIC_PLUGIN_COMPONENT_DIR="$plugin_dir" \
  LYRIC_PLUGIN_COMPONENT_FILE="greeter.wasm" \
  LYRIC_PLUGIN_COMPONENT_EXPECT=unavailable \
  LYRIC_WASMHOST_LIB="$wasmhost_lib" \
  LYRIC_WASMTIME_LIB="$work/no-such-libwasmtime.$ext" \
    "$LYRIC_BIN" test --target "$target" lyric-stdlib/tests/plugin_component_e2e_tests.l
done
