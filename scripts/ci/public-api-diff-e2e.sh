#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# public-api-diff-e2e.sh — `lyric public-api-diff` over multi-package
# libraries, end to end (#8927).
#
#   LYRIC_BIN=<lyric> bash scripts/ci/public-api-diff-e2e.sh
#
# A project-as-DLL bundle embeds one `Lyric.Contract.<Pkg>` resource per
# package (no bare `Lyric.Contract`). The diff must pair packages by name:
#   * identical bundles          -> exit 0, no changes
#   * an added func + package    -> exit 0, backwards-compatible
#   * a removed func             -> exit 2, BREAKING
#   * a removed package          -> exit 2, BREAKING
# and the real `Lyric.Stdlib.dll` must diff against itself without error.
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

# expect_diff <label> <expected-exit> <expected-text> <old.dll> <new.dll>
expect_diff() {
  local label="$1" want_rc="$2" want_text="$3" old="$4" new="$5" rc=0
  "$lyric_bin" public-api-diff "$old" "$new" > "$out" 2> "$err" < /dev/null || rc=$?
  [ "$rc" -eq "$want_rc" ] || fail "$label: expected exit $want_rc, got $rc"
  grep -q "$want_text" "$out" || fail "$label: expected '$want_text' in stdout"
  if grep -q "has no Lyric.Contract resource" "$err"; then fail "$label: contract resource not found"; fi
  echo "PASS: $label"
}

# make_lib <dir> <extra-A-funcs> <with-B> <with-C>
make_lib() {
  local dir="$1" extra="$2" withB="$3" withC="$4"
  mkdir -p "$dir/src"
  {
    echo '[package]'; echo 'name = "Multi"'; echo 'version = "0.1.0"'
    echo '[project]'; echo 'name = "Multi"'; echo 'output = "single"'; echo 'output_assembly = "Multi.dll"'
    echo '[project.packages]'; echo '"Multi.A" = "src/a.l"'
    if [ "$withB" = 1 ]; then echo '"Multi.B" = "src/b.l"'; fi
    if [ "$withC" = 1 ]; then echo '"Multi.C" = "src/c.l"'; fi
  } > "$dir/lyric.toml"
  printf 'package Multi.A\n\npub func one(): Int { 1 }\n%s' "$extra" > "$dir/src/a.l"
  printf 'package Multi.B\n\npub func two(): Int { 2 }\n' > "$dir/src/b.l"
  printf 'package Multi.C\n\npub func three(): Int { 3 }\n' > "$dir/src/c.l"
  "$lyric_bin" build --manifest "$dir/lyric.toml" > "$out" 2> "$err" < /dev/null || fail "build $dir"
}

dll_of() { find "$1" -name Multi.dll | head -1; }

make_lib "$work/base"    ''                                        1 0
make_lib "$work/same"    ''                                        1 0
make_lib "$work/addfn"   $'\npub func extra(): Int { 9 }\n'        1 0
make_lib "$work/rmfn"    ''                                        1 0
# rmfn drops A.one by rewriting a.l
printf 'package Multi.A\n\npub func other(): Int { 1 }\n' > "$work/rmfn/src/a.l"
"$lyric_bin" build --manifest "$work/rmfn/lyric.toml" > "$out" 2> "$err" < /dev/null || fail "rebuild rmfn"
make_lib "$work/addpkg"  ''                                        1 1

base="$(dll_of "$work/base")"
for d in same addfn rmfn addpkg; do [ -n "$(dll_of "$work/$d")" ] || fail "no Multi.dll for $d"; done

expect_diff "identical multi-package bundles" 0 "No public-API changes" "$base" "$(dll_of "$work/same")"
expect_diff "added func is compatible"        0 "backwards-compatible"   "$base" "$(dll_of "$work/addfn")"
expect_diff "removed func is breaking"        2 "BREAKING"               "$base" "$(dll_of "$work/rmfn")"
expect_diff "added package is compatible"     0 "package Multi.C (added)" "$base" "$(dll_of "$work/addpkg")"
expect_diff "removed package is breaking"     2 "package Multi.C (removed)" "$(dll_of "$work/addpkg")" "$base"

# The real stdlib bundle: many packages, no bare Lyric.Contract.
stdlib="$(find "$REPO_ROOT/.bootstrap" "$(dirname "$lyric_bin")" -name Lyric.Stdlib.dll 2>/dev/null | head -1)"
if [ -n "$stdlib" ]; then
  expect_diff "Lyric.Stdlib.dll against itself" 0 "No public-API changes" "$stdlib" "$stdlib"
else
  fail "Lyric.Stdlib.dll not found"
fi

echo "public-api-diff-e2e: all checks passed"
