#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# plugin-trusted-e2e.sh — run lyric-stdlib/tests/plugin_trusted_e2e_tests.l:
# a host loading a trusted plugin into its own process (docs/69 §10, D229).
#
# Usage: plugin-trusted-e2e.sh <lyric-binary> <target>
#
#   target  dotnet | jvm | native
#           the host's target and the plugin's: a trusted plugin is loaded
#           by a host of its own runtime
#
# Builds lyric-stdlib/tests/plugin_fixtures/trusted_notes/ into a fresh
# plugin directory: its process payload (the dotnet assembly, the jar, or a
# native executable) and its trusted payload (the same assembly or jar, or a
# `--shape plugin` shared library on native).  The suite probes the process
# payload with --lyric-plugin-manifest, writes plugin.json with both payloads,
# and hosts the plugin with policies that do and do not trust it.
# ---------------------------------------------------------------------------
set -euo pipefail

usage="usage: plugin-trusted-e2e.sh <lyric-binary> <dotnet|jvm|native>"
LYRIC_BIN="${1:?$usage}"
TARGET="${2:?$usage}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
case "$LYRIC_BIN" in
  /*) ;;
  *) LYRIC_BIN="$REPO_ROOT/$LYRIC_BIN" ;;
esac

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
plugin_dir="$work/plugins/trusted-notes"
mkdir -p "$plugin_dir"

fixture=lyric-stdlib/tests/plugin_fixtures/trusted_notes/lyric.toml
case "$TARGET" in
  dotnet)
    file="TrustedNotes.dll"
    library="$file"
    "$LYRIC_BIN" build --manifest "$fixture" --target dotnet -o "$plugin_dir/$file"
    ;;
  jvm)
    file="TrustedNotes.jar"
    library="$file"
    "$LYRIC_BIN" build --manifest "$fixture" --target jvm -o "$plugin_dir/$file"
    ;;
  native)
    file="trusted-notes"
    case "$(uname -s)" in
      Darwin) library="libtrusted-notes.dylib" ;;
      *) library="libtrusted-notes.so" ;;
    esac
    "$LYRIC_BIN" build --manifest "$fixture" --target native -o "$plugin_dir/$file"
    "$LYRIC_BIN" build --manifest "$fixture" --target native --shape plugin -o "$plugin_dir/$library"
    ;;
  *) echo "$usage" >&2; exit 2 ;;
esac

LYRIC_PLUGIN_FIXTURE_DIR="$plugin_dir" \
LYRIC_PLUGIN_FIXTURE_RUNTIME="$TARGET" \
LYRIC_PLUGIN_FIXTURE_FILE="$file" \
LYRIC_PLUGIN_FIXTURE_LIBRARY="$library" \
  "$LYRIC_BIN" test --target "$TARGET" lyric-stdlib/tests/plugin_trusted_e2e_tests.l
