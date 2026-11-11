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
#               guards and the SMTP/SES/SendGrid senders, exercised with every
#               provider feature active (`smtp,ses,sendgrid`); the Jakarta
#               Mail JARs are Maven-restored first (#7483, #7462)
#   mq          `Mq.messageFromJson` and the Idempotent/DeadLetter aspect
#               weaving over the in-process queue; an `[]` arm beside a
#               slice-typed arm of a `match` once failed class verification
#               (#7541)
#   proto       the protobuf wire codec; its IEEE 754 bit casts come from
#               Std.Math, which binds java.lang.Float/Double raw-bits methods
#
#   docker      the generated Docker API client, the tcp:// DOCKER_HOST path
#               and the Unix-socket fallback (Std.Http's JVM Unix-socket
#               transport, #8560) (#7511)
#   search      the request-deadline branch against a silent in-process
#               backend (`@cfg(target = "jvm")` test, #8571)
#   jobs        InProcessJobScheduler (a `List[JobSpec]` queue field read back
#               through the erased ArrayList) and the Retryable aspect
#   session     InProcessSessionStore (`Map[String, Record]` values) and the
#               Lettuce-backed kernel; Lettuce is Maven-restored first
#   auth        JWT/API-key verification and the B'-mode `ValidateKey` aspect
#               (`__LyricBModeCallContext` on the JVM, #4600)
#   aws-xray    the `AwsXRay.Tracing` B'-mode aspect over the X-Ray recorder
#   ws          frames, handshake and the WsSecurity aspects; the dotnet-only
#               `Ws.WsDotnetE2eTests` suite (it dials Std.TcpHost, which has
#               no JVM kernel) is left out with --suite
#   logging     Std.Logging's `LogLevel` enum beside the stdlib's
#               same-named `Std.Log.LogLevel` (type-scoped enum registry
#               keys are re-pointed per file)
#   db          Db.Kernel.Jvm over JDBC: the `@pN` -> `?` placeholder
#               translation, JDBC URL construction and the shared SQLite
#               suite (typed columns, transactions, error mapping) on
#               sqlite-jdbc; the PostgreSQL driver is Maven-restored with it
#               and checked for connect-failure mapping (#8932)
#   otel        OTLP/HTTP export through the JVM kernel (java.net.http) against
#               an in-process ServerSocket collector: path, content type,
#               headers, byte-exact protobuf body, 503 retry, deadline (#8953)
#   grpc        the client against an in-process grpc-java server (unary,
#               server streaming, metadata, deadlines, status mapping,
#               early stream cancel, #8527 / #5409) and the Resilience-backed
#               rate limiter; grpc-java is Maven-restored first. Server hosting
#               is #8642.
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
libs=(storage resilience mcp health generator-sdk web i18n cache feature-flags mail mq proto docker grpc search jobs session auth aws-xray ws logging db otel)
log_dir="$(mktemp -d)"
trap 'rm -rf "$log_dir"' EXIT

run_suite() {
  local lib="$1"
  # `web`, `mail` (Jakarta Mail, #7462), `grpc` (grpc-java),
  # `session` (Lettuce), `aws-xray` (X-Ray recorder), `ws` (Undertow) and `db`
  # (sqlite-jdbc, PostgreSQL JDBC) need
  # their Maven dependencies restored first; the shared helper
  # installs mvn if missing, builds the resolver under the same lock as the
  # other Maven call sites (#7108), restores, then runs the suite.
  local runner=(bash scripts/ci/self-test.sh --manifest "lyric-$lib/lyric.toml")
  case "$lib" in
    web|mail|grpc|session|aws-xray|ws|db)
      runner=(bash scripts/ci/manifest-jvm-maven-test.sh "lyric-$lib/lyric.toml")
      ;;
  esac
  # `Ws.WsDotnetE2eTests` dials Std.TcpHost, which has no JVM kernel, so the
  # JVM run names the target-independent suites instead.
  local suite_args=()
  if [ "$lib" = "ws" ]; then
    suite_args=(--suite Ws.WsTests --suite Ws.WsFrameTests --suite Ws.WsHandshakeTests --suite Ws.WsSecurityAspectWeavingTests)
  fi
  # `mail`'s provider backends (`smtp`/`ses`/`sendgrid`) are declared
  # behind their own `[features]` flags, off by default under
  # `--no-default-features`; activate all three so the suite exercises
  # every provider on this target, matching its `dotnet` default feature
  # set.
  local features="jvm"
  if [ "$lib" = "mail" ]; then
    features="jvm,smtp,ses,sendgrid"
  fi
  # `db`'s two drivers are features beside the kernel; both are compiled in,
  # as under the `dotnet` defaults.
  if [ "$lib" = "db" ]; then
    features="jvm,sqlite,postgres"
  fi
  # A manifest with no `[features]` table declares no feature to select
  # (`--features` naming one is F0050, #8362).
  local feature_args=(--no-default-features --features "$features")
  if ! grep -q '^\[features\]' "lyric-$lib/lyric.toml"; then
    feature_args=()
  fi
  # `search`'s features pick a backend (`elasticsearch` by default), not a
  # target, so it runs with its default feature set.
  if [ "$lib" = "search" ]; then
    feature_args=()
  fi
  "${runner[@]}" --target jvm "${feature_args[@]}" "${suite_args[@]}" \
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
