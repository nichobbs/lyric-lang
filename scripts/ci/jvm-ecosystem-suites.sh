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

BUILD_CONFIG="${BUILD_CONFIG:-Debug}"
lyric_bin="bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric"

failed=""
for lib in storage resilience jsonrpc mcp health generator-sdk web; do
  echo "=== lyric-$lib (--target jvm) ==="
  if [ "$lib" = "web" ]; then
    # Same lock as ci.yml's other `make maven-resolver` callers (the
    # lyric-web Undertow smoke step, the JVM auto-FFI bridge self-test) —
    # avoids two concurrent `mvn package` builds racing into the same
    # resolver/target/ output directory (#7108 follow-up).
    if ! flock /tmp/lyric-ci-maven-resolver-build.lock -c 'make maven-resolver'; then
      echo "::error::make maven-resolver failed; cannot restore lyric-web's Undertow dependency"
      failed="$failed lyric-web"
      continue
    fi
    export LYRIC_MAVEN_RESOLVER="$PWD/resolver/target/lyric-resolver.jar"
    if [ ! -x "$lyric_bin" ] || ! "$lyric_bin" restore --manifest "$PWD/lyric-web/lyric.toml"; then
      echo "::error::lyric restore --manifest lyric-web/lyric.toml failed"
      failed="$failed lyric-web"
      continue
    fi
  fi
  if ! bash scripts/ci/self-test.sh --manifest "lyric-$lib/lyric.toml" --target jvm --no-default-features --features jvm; then
    echo "::error::lyric-$lib suite failed on --target jvm"
    failed="$failed lyric-$lib"
  fi
done
if [ -n "$failed" ]; then
  echo "JVM ecosystem suites failed:$failed" >&2
  exit 1
fi
