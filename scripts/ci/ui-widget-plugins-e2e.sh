#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# ui-widget-plugins-e2e.sh — lyric-ui plugin widgets end to end (docs/65 §6.5,
# docs/69 §16 P6, D230).
#
# Usage: ui-widget-plugins-e2e.sh <lyric-binary> <host-target> <plugin-target>
#
#   host-target    dotnet | jvm | native   the target the host program is built for
#   plugin-target  dotnet | jvm | native | wasm
#                                          the payload the plugins are packed with;
#                                          wasm needs $WASI_SDK_PATH and
#                                          $LYRIC_RT_WASM32_PATH to build and runs
#                                          under wasmtime ($LYRIC_WASMTIME or PATH)
#
# Packs the example plugin (examples/plugins/ui-widgets/widgets) and the
# misbehaving fixture (lyric-ui/plugins/e2e/flaky) with `lyric plugin pack`
# into a plugins directory, checks both artifacts with `lyric plugin check`,
# builds lyric-ui/plugins/e2e/host for the host target and runs it against
# the directory. The host places the plugins' widgets in a screen driven by
# Ui.Host's session driver, sends events at them by their event paths and
# checks the rendered page; it prints one `ok`/`not ok` line per check and
# exits with the number of failures.
# ---------------------------------------------------------------------------
set -euo pipefail

usage="usage: ui-widget-plugins-e2e.sh <lyric-binary> <dotnet|jvm|native> <dotnet|jvm|native|wasm>"
LYRIC_BIN="${1:?$usage}"
HOST_TARGET="${2:?$usage}"
PLUGIN_TARGET="${3:?$usage}"

case "$HOST_TARGET" in
  dotnet|jvm|native) ;;
  *) echo "$usage" >&2; exit 2 ;;
esac
case "$PLUGIN_TARGET" in
  dotnet|jvm|native|wasm) ;;
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
plugins="$work/plugins"
mkdir -p "$plugins"

# A dotnet project build links its path dependencies' DLLs from their bin/
# directories, so the libraries are built first.
for manifest in lyric-ui/plugins/lyric.toml lyric-ui/plugins/build/lyric.toml lyric-ui/lyric.toml; do
  "$LYRIC_BIN" build --manifest "$manifest"
done

for manifest in examples/plugins/ui-widgets/widgets/lyric.toml lyric-ui/plugins/e2e/flaky/lyric.toml; do
  "$LYRIC_BIN" plugin pack --manifest "$manifest" --targets "$PLUGIN_TARGET" -o "$plugins"
done
rm -rf "$plugins/.lyric-pack-staging"
for artifact in "$plugins"/*/; do
  "$LYRIC_BIN" plugin check "$artifact"
done

host_manifest=lyric-ui/plugins/e2e/host/lyric.toml
"$LYRIC_BIN" restore --manifest "$host_manifest"
case "$HOST_TARGET" in
  dotnet)
    "$LYRIC_BIN" build --manifest "$host_manifest" -o "$work/host/UiPluginE2e.Host.dll"
    dotnet exec "$work/host/UiPluginE2e.Host.dll" "$plugins"
    ;;
  jvm)
    "$LYRIC_BIN" build --manifest "$host_manifest" --target jvm -o "$work/host/UiPluginE2e.Host.jar"
    java -jar "$work/host/UiPluginE2e.Host.jar" "$plugins"
    ;;
  native)
    "$LYRIC_BIN" build --manifest "$host_manifest" --target native -o "$work/host/ui-plugin-e2e-host"
    "$work/host/ui-plugin-e2e-host" "$plugins"
    ;;
esac
