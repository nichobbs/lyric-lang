#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# console-stdin-test.sh — run lyric-stdlib/tests/console_stdin_tests.l with a
# controlled stdin (#7451).
#
# Usage: console-stdin-test.sh <lyric-binary> [--target jvm]
#
# The program's first bounded stdin read must time out, so nothing may reach
# its stdin until it says so: it creates the marker file named by
# LYRIC_STDIN_TEST_MARKER once that read has timed out, and only then does
# the writer below send `late\n` and close the pipe. Compile time therefore
# cannot race the check. The writer gives up after 10 minutes so a program
# that dies before creating the marker cannot wedge the job.
# ---------------------------------------------------------------------------
set -euo pipefail

LYRIC_BIN="${1:?usage: console-stdin-test.sh <lyric-binary> [--target jvm]}"
shift

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
marker="$work/ready"

{
  waited=0
  while [ ! -e "$marker" ] && [ "$waited" -lt 6000 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  printf 'late\n'
} | LYRIC_STDIN_TEST_MARKER="$marker" "$LYRIC_BIN" run "$@" lyric-stdlib/tests/console_stdin_tests.l
