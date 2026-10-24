#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# plugin-component-pack-e2e.sh — `lyric plugin pack --targets component` and
# `lyric plugin check` for a component payload (docs/69 §9.3).
#
# Packs lyric-stdlib/tests/plugin_fixtures/notes_plugin.l as a component (and
# as a wasm32-wasi command, whose manifest must agree), checks the artifact,
# that plugin.json lists `{"mode": "component", ...}` and that the component's
# WIT sits beside it, and that check rejects a component payload whose file is
# missing or not a .wasm.
#
# Needs WASI_SDK_PATH, LYRIC_RT_WASM32_PATH, WASM_TOOLS, LYRIC_WASI_ADAPTER and
# LYRIC_WASMTIME (scripts/ci/wasm32-wasi-rt-tests.sh sets them).
#
# Usage: bash scripts/ci/plugin-component-pack-e2e.sh <lyric-binary>
# ---------------------------------------------------------------------------
set -euo pipefail

LYRIC="$1"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
for v in WASI_SDK_PATH LYRIC_RT_WASM32_PATH WASM_TOOLS LYRIC_WASI_ADAPTER LYRIC_WASMTIME; do
  [ -n "${!v:-}" ] || { echo "::error::$v is not set" >&2; exit 1; }
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
proj="$work/notes"
mkdir -p "$proj/src"
cp lyric-stdlib/tests/plugin_fixtures/notes_plugin.l "$proj/src/notes_plugin.l"
printf '[package]\nname = "notes"\nversion = "1.2.0"\n\n[project]\nname = "Notes"\noutput = "single"\n\n[project.packages]\n"PluginGen.Notes" = "src/notes_plugin.l"\n' >"$proj/lyric.toml"

echo "== lyric plugin pack --targets wasm,component"
"$LYRIC" plugin pack --manifest "$proj/lyric.toml" --targets wasm,component -o "$work/packed"
artifact="$work/packed/lyric.test.notes-1.2.0"
[ -f "$artifact/component/Notes.wasm" ] || { echo "::error::no component payload in $artifact" >&2; ls -R "$artifact" >&2; exit 1; }
[ -f "$artifact/component/Notes.wit" ] || { echo "::error::the component's WIT is not beside it" >&2; exit 1; }
grep -q '"mode": "component"' "$artifact/plugin.json" || { echo "::error::plugin.json lists no component payload" >&2; cat "$artifact/plugin.json" >&2; exit 1; }
grep -q '"component": "component/Notes.wasm"' "$artifact/plugin.json" || { echo "::error::the component payload names the wrong file" >&2; cat "$artifact/plugin.json" >&2; exit 1; }
grep -q '"id": "lyric.test.notes"' "$artifact/plugin.json" || { echo "::error::the probed manifest is missing" >&2; exit 1; }

echo "== lyric plugin check"
"$LYRIC" plugin check "$artifact"

expect_check_failure() { # label needle artifact-dir
  local out
  if out="$("$LYRIC" plugin check "$3" 2>&1)"; then
    echo "::error::plugin check accepted $1" >&2
    exit 1
  fi
  echo "$out" | grep -q "$2" || { echo "::error::plugin check on $1 did not say '$2':" >&2; echo "$out" >&2; exit 1; }
}

broken="$work/broken/lyric.test.notes-1.2.0"
mkdir -p "$(dirname "$broken")"
cp -r "$artifact" "$broken"
rm "$broken/component/Notes.wasm"
expect_check_failure "a missing component file" "does not exist" "$broken"
cp "$artifact/component/Notes.wasm" "$broken/component/Notes.wasm"
sed -i 's|"component": "component/Notes.wasm"|"component": "component/Notes.wit"|' "$broken/plugin.json"
expect_check_failure "a component that is not a .wasm" "expected a .wasm file" "$broken"

echo "plugin-component-pack-e2e: ok"
