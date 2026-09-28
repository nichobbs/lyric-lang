#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# console-stdout-bytes-test.sh — run
# lyric-stdlib/tests/console_stdout_bytes_tests.l and byte-diff its raw
# stdout against the exact UTF-8 encoding of the payload it writes (#7510).
#
# `Std.Console.writeStdoutBytes` must put the declared bytes on the wire
# verbatim — no text-writer re-encoding — so this compares raw bytes with
# `cmp`, never a shell string comparison (which would go through the
# invoking shell's own locale-dependent decoding).
#
# Usage: console-stdout-bytes-test.sh <lyric-binary> [--target jvm|--target native]
# ---------------------------------------------------------------------------
set -euo pipefail

LYRIC_BIN="${1:?usage: console-stdout-bytes-test.sh <lyric-binary> [--target jvm|--target native]}"
shift

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

"$LYRIC_BIN" run "$@" lyric-stdlib/tests/console_stdout_bytes_tests.l > "$work/raw"
# `lyric run` prints its own "built <path> in <N>ms" progress line to stdout
# ahead of the program's own output (cli_build.l's `Console.println`); strip
# that one line before comparing the program's raw bytes.
sed '/^built /d' "$work/raw" > "$work/actual"
python3 -c 'import sys; sys.stdout.buffer.write("café 😀 中文\n".encode("utf-8"))' > "$work/expected"

if ! cmp -s "$work/actual" "$work/expected"; then
  echo "console-stdout-bytes-test: FAILED — raw stdout bytes did not match the expected UTF-8 encoding" >&2
  echo "expected:" >&2
  od -An -tx1z "$work/expected" >&2
  echo "actual:" >&2
  od -An -tx1z "$work/actual" >&2
  exit 1
fi
echo "console-stdout-bytes-test: ok ($LYRIC_BIN run $* ...)"
