#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# plugin-e2e.sh — run lyric-stdlib/tests/plugin_e2e_tests.l against a real
# plugin process (docs/69, D207).
#
# Usage: plugin-e2e.sh <lyric-binary> <host-target> <plugin-target>
#
#   host-target    dotnet | jvm      the target the test suite (the host) runs on
#   plugin-target  dotnet | jvm | native | wasm
#                                    the target the fixture plugin is built for;
#                                    wasm builds a wasm32-wasi module (needs
#                                    $WASI_SDK_PATH and $LYRIC_RT_WASM32_PATH) and
#                                    runs it under wasmtime ($LYRIC_WASMTIME or PATH)
#
# Builds lyric-stdlib/tests/plugin_fixtures/greeter_plugin.l into a fresh
# plugin directory (<work>/plugins/greeter/), then runs the suite with
# LYRIC_PLUGIN_FIXTURE_{DIR,RUNTIME,FILE} pointing at it. The suite probes the
# payload with --lyric-plugin-manifest and writes plugin.json itself.
# ---------------------------------------------------------------------------
set -euo pipefail

usage="usage: plugin-e2e.sh <lyric-binary> <dotnet|jvm> <dotnet|jvm|native|wasm>"
LYRIC_BIN="${1:?$usage}"
HOST_TARGET="${2:?$usage}"
PLUGIN_TARGET="${3:?$usage}"

case "$HOST_TARGET" in
  dotnet|jvm) ;;
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
plugin_dir="$work/plugins/greeter"
mkdir -p "$plugin_dir"

fixture=lyric-stdlib/tests/plugin_fixtures/greeter_plugin.l
case "$PLUGIN_TARGET" in
  dotnet) file="greeter.dll" ;;
  jvm)    file="greeter.jar" ;;
  native) file="greeter" ;;
  wasm)   file="greeter.wasm" ;;
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
  "$LYRIC_BIN" test --target "$HOST_TARGET" lyric-stdlib/tests/plugin_e2e_tests.l
