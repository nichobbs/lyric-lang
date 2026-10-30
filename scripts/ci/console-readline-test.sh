#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# console-readline-test.sh -- run lyric-stdlib/tests/console_readline_tests.l
# with two lines piped into stdin (#7968).
#
# Usage: console-readline-test.sh <lyric-binary> [--target jvm|native]
# ---------------------------------------------------------------------------
set -euo pipefail

LYRIC_BIN="${1:?usage: console-readline-test.sh <lyric-binary> [--target jvm|native]}"
shift

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

printf 'alpha\nbeta\n' | "$LYRIC_BIN" run "$@" lyric-stdlib/tests/console_readline_tests.l
