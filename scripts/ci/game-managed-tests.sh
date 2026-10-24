#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# game-managed-tests.sh: lyric-game's pure core and Breakout's rules on the
# managed targets (#8516). They build on every target (D201); the native job
# runs them on dotnet only, and only when native code changes, so the
# `game` entry of ci.yml's ecosystem-tests matrix runs both targets on every
# change. --target jvm needs Java 21+ on PATH.
# Usage: LYRIC_CLI_PATH=<lyric> bash scripts/ci/game-managed-tests.sh
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
: "${LYRIC_CLI_PATH:?LYRIC_CLI_PATH must name the lyric binary}"

for target in dotnet jvm; do
  for manifest in lyric-game/lyric.toml lyric-game/examples/breakout/logic/lyric.toml; do
    echo "=== $manifest ($target) ==="
    "$LYRIC_CLI_PATH" test --target "$target" --manifest "$manifest"
  done
done
