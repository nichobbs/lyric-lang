#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# session-tests.sh: lyric-session's tests for the `session` entry of ci.yml's
# ecosystem-tests matrix (moved out of ci.yml to keep the workflow under its size
# ceiling, #6387). lyric-session's dotnet/jvm features are not default
# (StackExchange.Redis is a genuine mandatory NuGet dep for the dotnet kernel,
# unlike lyric-auth/lyric-storage's NuGet-free dotnet default) -- restore first,
# then activate the dotnet feature explicitly so Session.Kernel.Net and the
# Redis-dependent test files actually compile and run. The Cache.dll copy is
# needed because the runtimeconfig additionalProbingPaths only resolves
# NuGet-style versioned layouts, not plain path deps.
# Usage: LYRIC_CLI_PATH=<lyric> bash scripts/ci/session-tests.sh
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
: "${LYRIC_CLI_PATH:?LYRIC_CLI_PATH must name the lyric binary}"

mkdir -p lyric-session/.lyric-test
if [ -f lyric-cache/bin/Cache.dll ]; then
  cp lyric-cache/bin/Cache.dll lyric-session/.lyric-test/
else
  echo "::error::lyric-cache/bin/Cache.dll missing (should have been built as a path dependency above)"
  exit 1
fi
if ! "$LYRIC_CLI_PATH" restore --manifest lyric-session/lyric.toml; then
  echo "::error::failed to restore lyric-session NuGet dependencies"
  exit 1
fi
"$LYRIC_CLI_PATH" test --manifest lyric-session/lyric.toml --features dotnet
