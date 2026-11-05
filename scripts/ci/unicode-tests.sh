#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# unicode-tests.sh: lyric-unicode on the managed targets (D371, D372): its UAX #9
# and UAX #14 unit tests and Unicode's own conformance suites, on dotnet and the
# JVM, for the `unicode` entry of ci.yml's ecosystem-tests matrix. The native run
# of the conformance suites is in scripts/ci/ui-native-e2e.sh. --target jvm needs
# Java 21+ on PATH.
# Usage: LYRIC_CLI_PATH=<lyric> bash scripts/ci/unicode-tests.sh
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
: "${LYRIC_CLI_PATH:?LYRIC_CLI_PATH must name the lyric binary}"

# The tables of Unicode.Data are the ones its generator makes from the pinned UCD files (D373).
"$LYRIC_CLI_PATH" run --manifest lyric-unicode/tools/generate/lyric.toml -- --check
for target in dotnet jvm; do
  for manifest in lyric-unicode/lyric.toml lyric-unicode/tests/conformance/lyric.toml; do
    echo "=== $manifest ($target) ==="
    "$LYRIC_CLI_PATH" test --target "$target" --manifest "$manifest"
  done
done
