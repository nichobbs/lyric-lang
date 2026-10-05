#!/usr/bin/env bash
# `lyric prove` on a package of several files (#8108): a `Result`/`Option`
# type a sibling file declares is not the standard library's, in both the
# single-file and the --manifest mode, while an unrelated sibling type leaves
# the standard library's modelled.
#
#   LYRIC_BIN=<lyric> bash scripts/ci/prove-package-scope.sh
set -euo pipefail
lyric_bin="${LYRIC_BIN:?LYRIC_BIN must name the lyric binary}"
lyric_bin="$(cd "$(dirname "$lyric_bin")" && pwd)/$(basename "$lyric_bin")"
root="$(cd "$(dirname "$0")/../.." && pwd)/examples/prove-package-scope"
log="$(mktemp)"
trap 'rm -f "$log"' EXIT

expect() {
  local want="$1" label="$2"; shift 2
  local rc=0
  "$@" > "$log" 2>&1 || rc=$?
  if [ "$want" = proved ] && [ "$rc" -ne 0 ]; then
    echo "FAIL: $label: expected the proof to go through"; cat "$log"; exit 1
  fi
  if [ "$want" = rejected ] && [ "$rc" -eq 0 ]; then
    echo "FAIL: $label: expected the proof to fail"; cat "$log"; exit 1
  fi
  echo "PASS: $label"
}

expect rejected "shadow, single file" "$lyric_bin" prove "$root/shadow/src/p/b_logic.l"
expect rejected "shadow, --manifest" "$lyric_bin" prove --manifest "$root/shadow/lyric.toml"
expect proved "control, single file" "$lyric_bin" prove "$root/control/src/p/b_logic.l"
expect proved "control, --manifest" "$lyric_bin" prove --manifest "$root/control/lyric.toml"
