#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test-host-locale-c-test.sh — the JVM test-host class (`lowerTestModuleClass`)
# must rebind System.out to UTF-8 in its own <clinit> (#7686): a JUnit/IDE
# harness calls the `__lyric_test_<i>` methods directly and never runs the
# synthesised `main` that carries `emitConsoleUtf8Setup` (#7513).
#
# Runs lyric-compiler/jvm/self_test_b126.l, which builds a jar holding a test
# host class plus a verifier that loads it and prints a non-ASCII line, then
# runs that jar under `LC_ALL=C LANG=C` with no -Dfile.encoding flag and
# byte-compares the line against the expected UTF-8 bytes.
#
# Usage: test-host-locale-c-test.sh <lyric-binary>
# ---------------------------------------------------------------------------
set -euo pipefail

LYRIC_BIN="${1:?usage: test-host-locale-c-test.sh <lyric-binary>}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

LYRIC_LOAD_COMPILER=1 "$LYRIC_BIN" run lyric-compiler/jvm/self_test_b126.l > "$work/build_out"
grep -q '^jar_written=true$' "$work/build_out" || { echo "test-host-locale-c-test: jar was not written" >&2; cat "$work/build_out" >&2; exit 1; }

LC_ALL=C LANG=C java -jar /tmp/lyric-jvm-b126/test_engine.jar > "$work/raw" 2> "$work/err"
python3 -c 'import sys; sys.stdout.buffer.write("utf8=café 中文\n".encode("utf-8"))' > "$work/expected"
grep '^utf8=' "$work/raw" > "$work/actual" || true

if ! cmp -s "$work/actual" "$work/expected"; then
  echo "test-host-locale-c-test: FAILED - non-ASCII line did not survive LC_ALL=C" >&2
  echo "expected:" >&2; od -An -tx1z "$work/expected" >&2
  echo "actual:" >&2; od -An -tx1z "$work/actual" >&2
  exit 1
fi
echo "test-host-locale-c-test: ok"
