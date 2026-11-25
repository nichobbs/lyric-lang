#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# lyric-web-smoke.sh <dotnet|jvm> -- lyric-web smoke on one target, over the
# shared Std.HttpServer driver (docs/73 S6, D791).  Replaces the Undertow-only
# lyric-web-undertow-jvm-smoke.sh.
#
#   tests/web_smoke.l            builds the smoke server and exercises it end to
#                                end: HeaderMap, request-body echo, 404, the
#                                10 MiB request-body cap (413), the TLS phase
#                                2.2/2.3 in-process self-checks (MTLS-MISCONFIG,
#                                HTTPS-H2, MTLS-ACCEPT, MTLS-REJECT) and an
#                                independent `curl --http2` cross-check against
#                                the real HTTPS listener; also the regression
#                                pin of #5610 (cross-package impl-method
#                                parameter registration);
#   tests/serve_failure_tests.l  a handler panic answers 500 and the listener
#                                keeps serving (#5261), failure line logged;
#   tests/streaming_tests.l      chunked responses reach the client as they are
#                                written (#5979), the middleware gate (#5985).
#
# The JVM build still restores lyric-web's Maven dependencies: lyric-ws, which
# lyric-web depends on, carries the Undertow `[maven]` table until docs/73
# S7b deletes `Ws.Kernel.Jvm`; lyric-web itself has none.  Extracted from
# ci.yml (#6387/check-workflow-size.sh -- see scripts/ci/self-test.sh's header).
# ---------------------------------------------------------------------------
set -euo pipefail

target="${1:?usage: lyric-web-smoke.sh <dotnet|jvm>}"
case "$target" in dotnet|jvm) ;; *) echo "usage: lyric-web-smoke.sh <dotnet|jvm>" >&2; exit 2 ;; esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

BUILD_CONFIG="${BUILD_CONFIG:-Debug}"

lyric_bin="${LYRIC:-bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/lyric}"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin; skipping lyric-web smoke"
  exit 1
fi
lyric_bin="$(cd "$(dirname "$lyric_bin")" && pwd)/$(basename "$lyric_bin")"
if [ "$target" = jvm ]; then
  # Serialized against ci.yml's other `make maven-resolver` callers on the
  # same runner (the ecosystem suites' `web`, the UI suites and the lyric-ws
  # smoke): this step runs `background: true`, so without coordination two
  # concurrent `mvn package` builds could race into the same resolver/target/
  # output directory (#7108 follow-up).
  if [ -z "${LYRIC_MAVEN_RESOLVER:-}" ]; then
    flock /tmp/lyric-ci-maven-resolver-build.lock -c 'make maven-resolver'
    export LYRIC_MAVEN_RESOLVER="$PWD/resolver/target/lyric-resolver.jar"
  fi
  "$lyric_bin" restore --manifest "$PWD/lyric-web/lyric.toml"
fi

work="$(mktemp -d)"
srv_pid=""
cleanup() {
  [ -n "$srv_pid" ] && kill -- "-$srv_pid" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

# build <source relative to lyric-web> <name>: sets `run_cmd` to the command that runs the build.
build() {
  local src="$1" name="$2"
  if [ "$target" = jvm ]; then
    (cd lyric-web && "$lyric_bin" build --target jvm "$src" -o "$work/$name.jar")
    run_cmd=(java -jar "$work/$name.jar")
  else
    (cd lyric-web && "$lyric_bin" build --target dotnet "$src" -o "$work/$name.dll")
    run_cmd=(dotnet "$work/$name.dll")
  fi
}
# start <name> <health url> <seconds>: starts `run_cmd` in its own process group and waits for the URL.
start() {
  local name="$1" url="$2" tries="$3"
  setsid "${run_cmd[@]}" > "$work/$name.run.log" 2>&1 &
  srv_pid=$!
  local up=0
  for _ in $(seq 1 "$tries"); do
    if curl -s --max-time 1 -o /dev/null "$url"; then up=1; break; fi
    if ! kill -0 "$srv_pid" 2>/dev/null; then break; fi
    sleep 0.5
  done
  if [ "$up" != 1 ]; then
    echo "::error::$name server did not come up"
    tail -40 "$work/$name.run.log"
    exit 1
  fi
}
stop() {
  kill -- "-$srv_pid" 2>/dev/null || true
  wait "$srv_pid" 2>/dev/null || true
  srv_pid=""
}
fail=0
check() { # actual expected message
  [ "$1" = "$2" ] || { echo "::error::$3: got '$1', expected '$2'"; fail=1; }
}

# ---- web_smoke.l ---------------------------------------------------------------
build tests/web_smoke.l web_smoke
start web_smoke http://localhost:8099/hello/Ada 80
srv_log="$work/web_smoke.run.log"
hello="$(curl -s --max-time 3 http://localhost:8099/hello/Ada)"
header="$(curl -s --max-time 3 -H 'X-Test: abc' http://localhost:8099/echo-header)"
body="$(curl -s --max-time 3 -X POST --data 'ping' http://localhost:8099/echo-body)"
code404="$(curl -s --max-time 3 -o /dev/null -w '%{http_code}' http://localhost:8099/nope)"
# Request-body cap (#7233): Std.HttpEngine enforces EngineLimits.maxBodyBytes
# (10 MiB) on every target.  A body exactly at the limit is echoed in full; one
# byte over is refused with 413, whether its size is declared up front
# (Content-Length) or only discovered while reading (chunked), and whatever the
# method: a GET carrying an oversized body is refused too (#7325).
head -c 10485760 /dev/zero | tr '\0' 'a' > "$work/at-limit"
head -c 10485761 /dev/zero | tr '\0' 'a' > "$work/over-limit"
atlimit="$(curl -s --max-time 30 -o /dev/null -w '%{http_code}:%{size_download}' -X POST --data-binary @"$work/at-limit" http://localhost:8099/echo-body || echo 'curl-failed')"
overdeclared="$(curl -s --max-time 30 -o /dev/null -w '%{http_code}' -X POST --data-binary @"$work/over-limit" http://localhost:8099/echo-body || true)"
overchunked="$(curl -s --max-time 30 -o /dev/null -w '%{http_code}' -X POST -H 'Transfer-Encoding: chunked' --data-binary @"$work/over-limit" http://localhost:8099/echo-body || true)"
overget="$(curl -s --max-time 30 -o /dev/null -w '%{http_code}' -X GET --data-binary @"$work/over-limit" http://localhost:8099/hello/Ada || true)"
# TLS phase 2.2/2.3 (#5881/#6017): before the plaintext listener, main runs
# in-process self-checks and logs a single PASS/FAIL line each:
#   MTLS-MISCONFIG-SELFCHECK -- Web.serveTls with requireClientCert=true and NO
#     clientCa must return a typed ServerTlsUnsupported, never a crash or a
#     silent plaintext-auth listener (#6040).
#   HTTPS-H2-SELFCHECK -- a TLS-terminated listener (Web.serveTls) on :8100
#     driven by an in-process Std.Http client that trusts the fixture cert,
#     asserting 200 AND an h2-negotiated connection
#     (HttpResponse.negotiatedVersion); the client retries in a bounded poll
#     loop until the listener binds (#6028).
#   MTLS-ACCEPT-SELFCHECK / MTLS-REJECT-SELFCHECK -- a real mTLS listener on
#     :8102 (clientCa + requireClientCert=true): a client presenting a cert
#     signed by the configured CA gets a 200, a client presenting an unrelated
#     self-signed cert fails the TLS handshake.
# All of them run before the plaintext :8099 listener the wait above polled, so
# the lines are already in the log. An independent curl --http2 cross-checks h2
# against the real HTTPS listener.
selfcheck() { grep -o "$1: PASS.*" "$srv_log" | head -1 || true; }
h2selfcheck="$(selfcheck HTTPS-H2-SELFCHECK)"
mtlsmisconfigselfcheck="$(selfcheck MTLS-MISCONFIG-SELFCHECK)"
mtlsacceptselfcheck="$(selfcheck MTLS-ACCEPT-SELFCHECK)"
mtlsrejectselfcheck="$(selfcheck MTLS-REJECT-SELFCHECK)"
curlh2="$(curl -sk --http2 --max-time 4 -o /dev/null -w '%{http_version}:%{http_code}' https://127.0.0.1:8100/hello/Ada || echo 'curl-failed')"
stop
check "$hello" "Hello, Ada!" "hello endpoint"
check "$header" '{"xTest":"abc"}' "header endpoint"
check "$body" "ping" "body endpoint"
check "$code404" "404" "unmatched route HTTP status"
check "$atlimit" "200:10485760" "a body at the 10 MiB limit"
check "$overdeclared" "413" "an over-limit Content-Length body"
check "$overchunked" "413" "an over-limit chunked body"
check "$overget" "413" "a GET with an over-limit body"
[ -n "$h2selfcheck" ] || { echo "::error::HTTPS/h2 in-process self-check did not report PASS (Web.serveTls + negotiatedVersion)"; fail=1; }
[ -n "$mtlsmisconfigselfcheck" ] || { echo "::error::mTLS-misconfig self-check did not report PASS (requireClientCert with no clientCa -> typed ServerTlsUnsupported)"; fail=1; }
[ -n "$mtlsacceptselfcheck" ] || { echo "::error::mTLS-accept self-check did not report PASS (trusted client cert should connect)"; fail=1; }
[ -n "$mtlsrejectselfcheck" ] || { echo "::error::mTLS-reject self-check did not report PASS (untrusted client cert should be rejected at the TLS layer)"; fail=1; }
check "$curlh2" "2:200" "curl --http2 against the TLS listener"
if [ "$fail" != 0 ]; then
  tail -40 "$srv_log"
  exit 1
fi

# ---- serve_failure_tests.l: per-request crash isolation (#5261) ----------------
build tests/serve_failure_tests.l serve_failure
start serve_failure http://127.0.0.1:8199/health 80
check "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:8199/crash || echo 000)" "500" "/crash after a handler panic (#5261)"
grep -q "\[lyric-web\] request handling failed" "$work/serve_failure.run.log" \
  || { echo "::error::missing the [lyric-web] failure line in the serve_failure log (#5261)"; fail=1; }
check "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:8199/health || echo 000)" "200" "/health after a handler panic (the server must survive, #5261)"
stop
[ "$fail" = 0 ] || { tail -40 "$work/serve_failure.run.log"; exit 1; }

# ---- streaming_tests.l: chunked responses (#5979, #5985) -----------------------
build tests/streaming_tests.l streaming
start streaming http://127.0.0.1:8210/health 80
t0=$(date +%s%N)
curl -sN --max-time 5 -D "$work/stream_headers.txt" -o "$work/stream_body.txt" http://127.0.0.1:8210/stream
stream_ms=$(( ($(date +%s%N) - t0) / 1000000 ))
# /stream sleeps 400 ms between its two chunks: a response that took less was buffered, not streamed.
[ "$stream_ms" -ge 350 ] || { echo "::error::/stream returned in ${stream_ms}ms, expected at least 400ms (chunks were buffered)"; fail=1; }
{ grep -q chunk0 "$work/stream_body.txt" && grep -q chunk1 "$work/stream_body.txt"; } \
  || { echo "::error::/stream body is missing its chunk markers"; fail=1; }
grep -qi "Transfer-Encoding: *chunked" "$work/stream_headers.txt" || { echo "::error::/stream is missing Transfer-Encoding: chunked"; fail=1; }
! grep -qi "Content-Length" "$work/stream_headers.txt" || { echo "::error::/stream set a Content-Length"; fail=1; }
check "$(curl -s --max-time 3 http://127.0.0.1:8210/empty || true)" "" "/empty body (a handler that never writes)"
check "$(curl -s --max-time 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:8210/created || true)" "201" "/created (writeStatus 201)"
check "$(curl -s --max-time 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:8210/blocked || true)" "403" "/blocked (the middleware must reject before the streaming handler runs)"
kill -0 "$srv_pid" 2>/dev/null || { echo "::error::the streaming server died handling /blocked"; fail=1; }
stop
[ "$fail" = 0 ] || { tail -40 "$work/streaming.run.log"; exit 1; }

echo "lyric-web smoke passed on $target (4/4 plaintext endpoints + 10 MiB body cap (413) + HTTPS/h2 serveTls: $h2selfcheck; mTLS-misconfig: $mtlsmisconfigselfcheck; mTLS-accept: $mtlsacceptselfcheck; mTLS-reject: $mtlsrejectselfcheck; curl --http2 $curlh2; crash isolation; chunked streaming)" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
echo "lyric-web smoke passed on $target"
