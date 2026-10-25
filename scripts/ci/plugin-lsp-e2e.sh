#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# plugin-lsp-e2e.sh — the protocol-point example end to end (docs/69 §4.3):
# examples/plugins/lsp/editor hosting examples/plugins/lsp/todo-server, a
# language server, over LSP.
#
# Usage: plugin-lsp-e2e.sh <lyric-binary> <host-target>
#
#   host-target    dotnet | jvm   the target the editor is built for
#
# Builds both payloads of the server into an artifact directory
# (<work>/plugins/example.todo-lsp-1.0.0/) with its hand-written plugin.json,
# checks it with `lyric plugin check`, builds the editor, and runs it against
# the directory. The editor runs the payload of its own runtime; cross-runtime
# pairs are covered by plugin-protocol-e2e.sh.
# The editor prints one `ok`/`not ok` line per check and exits with the
# number of failures.
# ---------------------------------------------------------------------------
set -euo pipefail

usage="usage: plugin-lsp-e2e.sh <lyric-binary> <dotnet|jvm>"
LYRIC_BIN="${1:?$usage}"
HOST_TARGET="${2:?$usage}"

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
example=examples/plugins/lsp
artifact="$work/plugins/example.todo-lsp-1.0.0"
mkdir -p "$artifact"

"$LYRIC_BIN" build --manifest "$example/todo-server/lyric.toml" -o "$artifact/TodoLsp.dll"
"$LYRIC_BIN" build --manifest "$example/todo-server/lyric.toml" --target jvm -o "$artifact/TodoLsp.jar"
cp "$example/todo-server/plugin/plugin.json" "$artifact/plugin.json"
# The editor loads only plugins signed with the example publisher key (D248).
"$LYRIC_BIN" plugin sign "$artifact" --key examples/plugins/keys/example-publisher.key
"$LYRIC_BIN" plugin check "$artifact"

case "$HOST_TARGET" in
  dotnet)
    "$LYRIC_BIN" build --manifest "$example/editor/lyric.toml" -o "$work/editor/Editor.dll"
    dotnet exec "$work/editor/Editor.dll" "$work/plugins"
    ;;
  jvm)
    "$LYRIC_BIN" build --manifest "$example/editor/lyric.toml" --target jvm -o "$work/editor/Editor.jar"
    java -jar "$work/editor/Editor.jar" "$work/plugins"
    ;;
esac
