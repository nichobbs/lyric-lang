#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# println-stringify-e2e.sh — check that `println(x)` writes exactly what
# `toString(x)` returns for a value with no dedicated console overload
# (#7858).
#
#   BUILD_CONFIG=Release bash scripts/ci/println-stringify-e2e.sh
#
# A test cannot capture its own stdout, so each self-test below prints a value
# and then its `toString`, in pairs, between `println-pairs-begin` and
# `println-pairs-end`.  This runs each one and fails unless every pair is
# equal and the expected number of pairs was printed:
#
#   println_stringify_self_test.l          dotnet + jvm  records, unions,
#                                                        lists, slices, Double
#   println_extern_struct_dotnet_self_test.l dotnet      extern BCL structs
#   println_extern_jvm_self_test.l         jvm           extern JDK objects
#
# Invoked from `compiler-self-tests-batch.sh` (whose CI job has Java 21), so
# it needs no ci.yml step of its own.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

BUILD_CONFIG="${BUILD_CONFIG:-Debug}"
lyric_bin="${LYRIC_BIN:-$REPO_ROOT/bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric}"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin; cannot run println-stringify e2e" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail=0

# check_pairs <target> <self-test> <expected pair count>
check_pairs() {
  local target="$1" test_file="$2" want="$3"
  local stem log pairs n
  stem="$(basename "$test_file" .l)"
  log="$work/$stem-$target.log"
  if ! "$lyric_bin" test --target "$target" "$test_file" >"$log" 2>&1; then
    echo "::error::$stem failed on --target $target" >&2
    cat "$log" >&2
    fail=1
    return
  fi
  pairs="$work/$stem-$target.pairs"
  sed -n '/^println-pairs-begin$/,/^println-pairs-end$/p' "$log" | sed '1d;$d' >"$pairs"
  n="$(wc -l <"$pairs")"
  if [[ "$n" -ne $((want * 2)) ]]; then
    echo "::error::$stem on --target $target printed $n lines between the markers; expected $((want * 2))" >&2
    cat -v "$pairs" >&2
    fail=1
    return
  fi
  local bad=0 i printed expected
  for ((i = 1; i <= want; i++)); do
    printed="$(sed -n "$((2 * i - 1))p" "$pairs")"
    expected="$(sed -n "$((2 * i))p" "$pairs")"
    if [[ "$printed" != "$expected" ]]; then
      echo "::error::$stem on --target $target, pair $i: println printed '$(printf '%s' "$printed" | cat -v)', toString is '$expected'" >&2
      bad=1
    fi
  done
  if [[ "$bad" -ne 0 ]]; then
    fail=1
  else
    echo "println-stringify e2e ($stem, $target): OK ($want pairs)"
  fi
}

check_pairs dotnet lyric-compiler/lyric/println_stringify_self_test.l 8
check_pairs jvm lyric-compiler/lyric/println_stringify_self_test.l 8
check_pairs dotnet lyric-compiler/lyric/println_extern_struct_dotnet_self_test.l 7
check_pairs jvm lyric-compiler/lyric/println_extern_jvm_self_test.l 3
exit "$fail"
