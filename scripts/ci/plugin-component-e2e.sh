#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# plugin-component-e2e.sh — run lyric-stdlib/tests/plugin_component_e2e_tests.l:
# a component plugin hosted in-process by Std.PluginWasm (docs/69 §9.3).
#
# Usage: plugin-component-e2e.sh <host-target>...
#
#   host-target  dotnet | jvm | native  (one or more)
#
# The lyric binary is $LYRIC_BIN, else the AOT build
# (bootstrap/src/Lyric.Cli.Aot/bin/$BUILD_CONFIG/net10.0/lyric).
#
# Packs the @plugin package lyric-stdlib/tests/plugin_fixtures/greeter_component.l
# with `lyric plugin pack --targets component` (so the component is generated
# by Lyric.PluginExpand, docs/69 §9.3, D247), builds the in-process embedding
# (`make -C lyric-rt wasmhost`, and lyric_rt.a for a native host), and fetches
# the pinned wasmtime C API (scripts/ci/fetch-wasmtime-capi.sh).  Each host
# then runs the suite twice: with libwasmtime available
# ($LYRIC_WASMTIME_LIB), and with it deliberately missing, where only the
# fallback is checked.  dotnet and JVM hosts load the embedding's library
# from $LYRIC_WASMHOST_LIB.
#
# The component build needs the wasm32 toolchain: $WASI_SDK_PATH,
# $LYRIC_RT_WASM32_PATH, $WASM_TOOLS and $LYRIC_WASI_ADAPTER, and pack reads
# the component's manifest with the wasmtime CLI ($LYRIC_WASMTIME).  When they
# are unset, scripts/ci/fetch-wasm-toolchain.sh fetches the pinned wasi-sdk,
# wasm-tools, preview1 adapter and wasmtime CLI, and lyric-rt is cross-built
# for wasm32.
# The JVM host needs a JDK 22 or later `java` on PATH (D158, D229).
# ---------------------------------------------------------------------------
set -euo pipefail

usage="usage: plugin-component-e2e.sh <dotnet|jvm|native>..."
[ "$#" -gt 0 ] || { echo "$usage" >&2; exit 2; }
for target in "$@"; do
  case "$target" in
    dotnet|jvm|native) ;;
    *) echo "$usage" >&2; exit 2 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
LYRIC_BIN="${LYRIC_BIN:-bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG:-Debug}/net10.0/lyric}"
case "$LYRIC_BIN" in
  /*) ;;
  *) LYRIC_BIN="$REPO_ROOT/$LYRIC_BIN" ;;
esac
if [ ! -x "$LYRIC_BIN" ]; then
  echo "::error::lyric binary not found at $LYRIC_BIN; cannot run the component plugin e2e" >&2
  exit 1
fi

if [ -z "${WASI_SDK_PATH:-}" ] || [ -z "${WASM_TOOLS:-}" ] || [ -z "${LYRIC_WASI_ADAPTER:-}" ] ||
  [ -z "${LYRIC_WASMTIME:-}" ]; then
  # shellcheck source=scripts/ci/fetch-wasm-toolchain.sh
  source scripts/ci/fetch-wasm-toolchain.sh
  export WASI_SDK_PATH="${WASI_SDK_PATH:-$LYRIC_WASI_SDK_DIR}" \
    WASM_TOOLS="${WASM_TOOLS:-$LYRIC_WASM_TOOLS_BIN}" \
    LYRIC_WASI_ADAPTER="${LYRIC_WASI_ADAPTER:-$LYRIC_WASI_ADAPTER_FILE}" \
    LYRIC_WASMTIME="${LYRIC_WASMTIME:-$LYRIC_WASMTIME_CLI}"
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
proj="$work/greeter"
mkdir -p "$proj/src"
cp lyric-stdlib/tests/plugin_fixtures/greeter_component.l "$proj/src/greeter_component.l"
printf '[package]\nname = "greeter"\nversion = "1.0.0"\n\n[project]\nname = "Greeter"\noutput = "single"\n\n[project.packages]\n"Fixture.Api" = "src/greeter_component.l"\n' >"$proj/lyric.toml"
"$LYRIC_BIN" plugin pack --manifest "$proj/lyric.toml" --targets component -o "$work/plugins"
plugin_dir="$work/plugins/lyric.test.greeter-component-1.0.0"
component_file="component/Greeter.wasm"
[ -f "$plugin_dir/$component_file" ] || { echo "::error::pack wrote no component payload" >&2; ls -R "$work/plugins" >&2; exit 1; }

for target in "$@"; do
  if [ "$target" = native ]; then
    make -C lyric-rt >/dev/null
  fi
  echo "=== plugin_component_e2e_tests.l (--target $target, libwasmtime available) ==="
  LYRIC_PLUGIN_COMPONENT_DIR="$plugin_dir" \
  LYRIC_PLUGIN_COMPONENT_FILE="$component_file" \
  LYRIC_PLUGIN_COMPONENT_EXPECT=available \
  LYRIC_WASMHOST_LIB="$wasmhost_lib" \
  LYRIC_WASMTIME_LIB="$wasmtime_lib" \
    "$LYRIC_BIN" test --target "$target" lyric-stdlib/tests/plugin_component_e2e_tests.l
  echo "=== plugin_component_e2e_tests.l (--target $target, libwasmtime missing) ==="
  LYRIC_PLUGIN_COMPONENT_DIR="$plugin_dir" \
  LYRIC_PLUGIN_COMPONENT_FILE="$component_file" \
  LYRIC_PLUGIN_COMPONENT_EXPECT=unavailable \
  LYRIC_WASMHOST_LIB="$wasmhost_lib" \
  LYRIC_WASMTIME_LIB="$work/no-such-libwasmtime.$ext" \
    "$LYRIC_BIN" test --target "$target" lyric-stdlib/tests/plugin_component_e2e_tests.l
done
