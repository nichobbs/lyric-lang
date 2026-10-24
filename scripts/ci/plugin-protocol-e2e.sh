#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# plugin-protocol-e2e.sh — run lyric-stdlib/tests/plugin_protocol_e2e_tests.l
# against a real protocol plugin process (docs/69 §4.3).
#
# Usage: plugin-protocol-e2e.sh <lyric-binary> <host-target> <plugin-target>
#
#   host-target    dotnet | jvm | native
#                                    the target the test suite (the host) runs on
#   plugin-target  dotnet | jvm | native | wasm
#                                    the target the fixture plugin is built for;
#                                    wasm builds a wasm32-wasi module (needs
#                                    $WASI_SDK_PATH and $LYRIC_RT_WASM32_PATH) and
#                                    runs it under wasmtime ($LYRIC_WASMTIME or PATH)
#
# Builds lyric-stdlib/tests/plugin_fixtures/echo_protocol_plugin.l into a fresh
# plugin directory (<work>/plugins/echo/), then runs the suite with
# LYRIC_PLUGIN_FIXTURE_{DIR,RUNTIME,FILE} pointing at it. A protocol plugin
# has no generated manifest; the suite registers one built in memory.
# ---------------------------------------------------------------------------
set -euo pipefail

usage="usage: plugin-protocol-e2e.sh <lyric-binary> <dotnet|jvm|native> <dotnet|jvm|native|wasm>"
LYRIC_BIN="${1:?$usage}"
HOST_TARGET="${2:?$usage}"
PLUGIN_TARGET="${3:?$usage}"

case "$HOST_TARGET" in
  dotnet|jvm|native) ;;
  *) echo "$usage" >&2; exit 2 ;;
esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
case "$LYRIC_BIN" in
  /*) ;;
  *) LYRIC_BIN="$REPO_ROOT/$LYRIC_BIN" ;;
esac

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
plugin_dir="$work/plugins/echo"
mkdir -p "$plugin_dir"

fixture=lyric-stdlib/tests/plugin_fixtures/echo_protocol_plugin.l
case "$PLUGIN_TARGET" in
  dotnet) file="echo.dll" ;;
  jvm)    file="echo.jar" ;;
  native) file="echo" ;;
  wasm)   file="echo.wasm" ;;
  *) echo "$usage" >&2; exit 2 ;;
esac

if [ "$PLUGIN_TARGET" = wasm ]; then
  "$LYRIC_BIN" build "$fixture" --target native --triple wasm32-wasi -o "$plugin_dir/$file"
else
  "$LYRIC_BIN" build "$fixture" --target "$PLUGIN_TARGET" -o "$plugin_dir/$file"
fi

LYRIC_PLUGIN_FIXTURE_DIR="$plugin_dir" \
LYRIC_PLUGIN_FIXTURE_RUNTIME="$PLUGIN_TARGET" \
LYRIC_PLUGIN_FIXTURE_FILE="$file" \
  "$LYRIC_BIN" test --target "$HOST_TARGET" lyric-stdlib/tests/plugin_protocol_e2e_tests.l
