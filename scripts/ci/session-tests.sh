#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# session-tests.sh: lyric-session's tests for the `session` entry of ci.yml's
# ecosystem-tests matrix (moved out of ci.yml to keep the workflow under its size
# ceiling, #6387). lyric-session is pure Lyric with no third-party dependency
# (its Redis backend moved to lyric-ecosystem's `session-redis`, D614), so there
# is nothing to restore and no feature to select.
# Usage: LYRIC_CLI_PATH=<lyric> bash scripts/ci/session-tests.sh
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
: "${LYRIC_CLI_PATH:?LYRIC_CLI_PATH must name the lyric binary}"

"$LYRIC_CLI_PATH" test --manifest lyric-session/lyric.toml
