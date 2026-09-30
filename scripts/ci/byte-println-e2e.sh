#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# byte-println-e2e.sh — check the text `println(<Byte>)` writes, on both
# targets (#7852).
#
#   BUILD_CONFIG=Release bash scripts/ci/byte-println-e2e.sh
#
# `lyric-compiler/lyric/byte_stringify_self_test.l` asserts every in-process
# `Byte` stringification (toString, `.toString()`, interpolation, `String +`),
# but a test cannot capture its own stdout, so its "println of a Byte" test
# only proves printing runs.  This runs that self-test on `--target dotnet`
# and `--target jvm` and compares the six lines it prints just before its
# `byte-println-end` marker against the unsigned values it prints: a local,
# a local, a record field, a slice element, a call result and a generic
# `Box[Byte]` field.  Invoked from `compiler-self-tests-batch.sh` (whose CI
# job already has Java 21), so it needs no ci.yml step of its own.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

BUILD_CONFIG="${BUILD_CONFIG:-Debug}"
lyric_bin="${LYRIC_BIN:-$REPO_ROOT/bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric}"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin; cannot run byte-println e2e" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

expected=$'0\n255\n128\n127\n200\n200'
fail=0
for target in dotnet jvm; do
  log="$work/$target.log"
  if ! "$lyric_bin" test --target "$target" lyric-compiler/lyric/byte_stringify_self_test.l >"$log" 2>&1; then
    echo "::error::byte_stringify_self_test.l failed on --target $target" >&2
    cat "$log" >&2
    fail=1
    continue
  fi
  actual="$(grep -B6 -x 'byte-println-end' "$log" | head -n 6)"
  if [[ "$actual" != "$expected" ]]; then
    echo "::error::println(<Byte>) on --target $target printed:" >&2
    printf '%s\n' "$actual" >&2
    echo "expected:" >&2
    printf '%s\n' "$expected" >&2
    fail=1
  else
    echo "byte-println e2e ($target): OK"
  fi
done
exit "$fail"
