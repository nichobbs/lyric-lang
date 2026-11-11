#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# publish-stability-e2e.sh — `[package] stability` and `lyric publish`
# (D552 item 4), end to end.
#
#   LYRIC_BIN=<lyric> bash scripts/ci/publish-stability-e2e.sh
#
#   * stability = "incomplete"  -> publish exits 1 with F0052, before any
#                                  DLL lookup or network access
#   * stability = "beta"        -> publish exits 1 with the F0051 parse error
#   * stability = "stable" / "experimental" / absent -> publish gets past the
#     stability check (it then stops at the missing DLL, with no registry
#     contact)
#
# Invoked from `compiler-self-tests-batch.sh`.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_CONFIG="${BUILD_CONFIG:-Debug}"
lyric_bin="${LYRIC_BIN:-$REPO_ROOT/bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric}"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin" >&2
  exit 1
fi
lyric_bin="$(cd "$(dirname "$lyric_bin")" && pwd)/$(basename "$lyric_bin")"

work="$(mktemp -d)"
trap 'rm -rf "${work:?}"' EXIT
out="$work/stdout"
err="$work/stderr"

fail() {
  echo "FAIL: $1"
  echo "--- stdout"; cat "$out"
  echo "--- stderr"; cat "$err"
  exit 1
}

# publish_with <label> <stability-line-or-empty> <expected-exit> <expected-stderr-text> <unexpected-stderr-text-or-empty>
publish_with() {
  local label="$1" line="$2" want_rc="$3" want_text="$4" deny_text="$5" rc=0
  local dir="$work/$label"
  mkdir -p "$dir"
  {
    echo '[package]'; echo 'name = "StabilityProbe"'; echo 'version = "0.1.0"'
    if [ -n "$line" ]; then echo "$line"; fi
  } > "$dir/lyric.toml"
  "$lyric_bin" publish --manifest "$dir/lyric.toml" > "$out" 2> "$err" < /dev/null || rc=$?
  [ "$rc" -eq "$want_rc" ] || fail "$label: expected exit $want_rc, got $rc"
  grep -q -- "$want_text" "$err" || fail "$label: expected '$want_text' on stderr"
  if [ -n "$deny_text" ] && grep -q -- "$deny_text" "$err"; then fail "$label: unexpected '$deny_text' on stderr"; fi
  echo "PASS: $label"
}

publish_with incomplete   'stability = "incomplete"'   1 'error\[F0052\]'   ''
publish_with invalid      'stability = "beta"'         1 'F0051'           'F0052'
publish_with not-a-string 'stability = 3'              1 'F0051'           'F0052'
publish_with stable       'stability = "stable"'       1 'DLL not found'   'F0052'
publish_with experimental 'stability = "experimental"' 1 'DLL not found'   'F0052'
publish_with undeclared   ''                           1 'DLL not found'   'F0052'

echo "publish-stability-e2e: all checks passed"
