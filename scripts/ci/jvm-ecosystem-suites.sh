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
#   health      runCheckIsolated's bounded-wait timeout enforcement + panic
#               isolation, both real on jvm now via Std.Task.runWithin (#7461)
#   generator-sdk  slice `.toArray()`, literal `String.split` (#7480, #7511)
#   web         Web.Kernel.Runtime's Undertow server, dispatch, aspects,
#               worker loop, TLS/mTLS round trip (#7578)
#   i18n        I18n.Kernel handle-based translation store, cross-package
#               bare-name resolution between the `I18n` and `I18n.Kernel`
#               sibling packages (#7458)
#   cache       InProcessCacheStore + FunctionCache/ItemCache aspect
#               weaving, pure Lyric with no extern boundary (#7483)
#   feature-flags  InProcessFlagStore, Flags.Registry, and the FlagGated/
#               FlagVariant aspect templates; fixed the JVM backend's
#               cross-package private-callee resolution gap the weaver's
#               `around` advice splicing exposed (`checkFlagName`, #7483)
#   mail        Mail's typed envelope, header-injection/attachment-size
#               guards, and the real `System.Net.Mail`-backed SMTP
#               transport's dotnet-only reachability, exercised with every
#               provider feature active (`smtp,ses,sendgrid`) so the
#               `NOT_IMPLEMENTED` provider paths are honestly asserted on
#               `jvm` too (#7483)
#
# Replaces one ci.yml step per library (ci.yml is at its size ceiling,
# scripts/ci/check-workflow-size.sh). Every suite runs even after a failure;
# the script fails if any did.
#
# The suites are independent (each builds into its own library directory;
# `web`'s Maven resolver build is serialized by manifest-jvm-maven-test.sh's
# lock), so they run LYRIC_JVM_SUITE_JOBS at a time (default 3). Run one after
# another they were the longest step of the JVM self-test jobs. Each
# suite's output goes to its own log, printed in suite order afterwards so the
# CI log stays readable.
# ---------------------------------------------------------------------------
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

max_jobs="${LYRIC_JVM_SUITE_JOBS:-3}"
if ! [[ "$max_jobs" =~ ^[1-9][0-9]*$ ]]; then
  echo "::error::LYRIC_JVM_SUITE_JOBS must be a positive integer, got '$max_jobs'" >&2
  exit 1
fi
libs=(storage resilience jsonrpc mcp health generator-sdk web i18n cache feature-flags mail)
log_dir="$(mktemp -d)"
trap 'rm -rf "$log_dir"' EXIT

run_suite() {
  local lib="$1"
  # `web` needs its Maven dependency restored first; the shared helper
  # installs mvn if missing, builds the resolver under the same lock as the
  # other Maven call sites (#7108), restores, then runs the suite.
  local runner=(bash scripts/ci/self-test.sh --manifest "lyric-$lib/lyric.toml")
  if [ "$lib" = "web" ]; then
    runner=(bash scripts/ci/manifest-jvm-maven-test.sh "lyric-$lib/lyric.toml")
  fi
  # `mail`'s provider backends (`smtp`/`ses`/`sendgrid`) are declared
  # behind their own `[features]` flags, off by default under
  # `--no-default-features`; activate all three so the suite exercises
  # (and honestly asserts the `NOT_IMPLEMENTED` status of) every provider
  # on this target, matching its `dotnet` default feature set.
  local features="jvm"
  if [ "$lib" = "mail" ]; then
    features="jvm,smtp,ses,sendgrid"
  fi
  "${runner[@]}" --target jvm --no-default-features --features "$features" \
    > "$log_dir/$lib.log" 2>&1
  echo $? > "$log_dir/$lib.rc"
}

running=0
for lib in "${libs[@]}"; do
  if [ "$running" -ge "$max_jobs" ]; then
    wait -n
    running=$((running - 1))
  fi
  # A start line per suite, so a hung suite is visible while the step runs;
  # the full output is printed in suite order once every suite has finished.
  echo "--- starting lyric-$lib (--target jvm)"
  run_suite "$lib" &
  running=$((running + 1))
done
wait

failed=""
for lib in "${libs[@]}"; do
  echo "=== lyric-$lib (--target jvm) ==="
  cat "$log_dir/$lib.log"
  rc="$(cat "$log_dir/$lib.rc" 2>/dev/null || echo 1)"
  if [ "$rc" != "0" ]; then
    echo "::error::lyric-$lib suite failed on --target jvm"
    failed="$failed lyric-$lib"
  fi
done
if [ -n "$failed" ]; then
  echo "JVM ecosystem suites failed:$failed" >&2
  exit 1
fi
