#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# jvm-ecosystem-suites.sh — run the pure-Lyric ecosystem library suites on
# --target jvm, one `lyric test --manifest` each.  Every one of these except
# `web` needs no Maven restore; `web` depends on `io.undertow:undertow-core`
# (see lyric-web/lyric.toml's `[maven]` table) and is restored first.
#
#   bash scripts/ci/jvm-ecosystem-suites.sh
#
# Each suite's coverage:
#   storage     multi-package JVM project build, @cfg dotnet/jvm kernel split,
#               Storage.Kernel.Jvm and the Std.Json JVM kernel (#1444/#2669)
#   resilience  Resilience.Kernel.Jvm circuit breaker / retry (#5037)
#   jsonrpc     call deadlines against silent and late peers (#7451)
#   mcp         client timeouts over real child processes (#7451)
#   health      runCheckIsolated's jvm arm, panic isolation (#7461)
#   generator-sdk  slice `.toArray()`, literal `String.split` (#7480, #7511)
#   web         Web.Kernel.Runtime's Undertow server, dispatch, aspects,
#               worker loop, TLS/mTLS round trip (#7578)
#
# Replaces one ci.yml step per library (ci.yml is at its size ceiling,
# scripts/ci/check-workflow-size.sh). Every suite runs even after a failure;
# the script fails if any did.
# ---------------------------------------------------------------------------
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"


failed=""
for lib in storage resilience jsonrpc mcp health generator-sdk web; do
  echo "=== lyric-$lib (--target jvm) ==="
  # `web` needs its Maven dependency restored first; the shared helper
  # installs mvn if missing, builds the resolver under the same lock as the
  # other Maven call sites (#7108), restores, then runs the suite.
  runner=(bash scripts/ci/self-test.sh --manifest "lyric-$lib/lyric.toml")
  if [ "$lib" = "web" ]; then
    runner=(bash scripts/ci/manifest-jvm-maven-test.sh "lyric-$lib/lyric.toml")
  fi
  if ! "${runner[@]}" --target jvm --no-default-features --features jvm; then
    echo "::error::lyric-$lib suite failed on --target jvm"
    failed="$failed lyric-$lib"
  fi
done
if [ -n "$failed" ]; then
  echo "JVM ecosystem suites failed:$failed" >&2
  exit 1
fi
