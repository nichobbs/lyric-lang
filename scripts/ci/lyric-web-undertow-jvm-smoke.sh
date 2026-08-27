#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# lyric-web-undertow-jvm-smoke.sh — lyric-web Undertow smoke on JVM
# (tests/jvm_server_smoke.l): restores lyric-web's Maven deps, builds the
# smoke server as a bundled JVM jar (cross-package impl-method parameter
# registration regression pin, #5610), and exercises it end to end --
# HeaderMap, request-body echo, 404, plus the TLS phase 2.2/2.3 in-process
# self-checks (MTLS-MISCONFIG, HTTPS-H2, MTLS-ACCEPT, MTLS-REJECT) and an
# independent `curl --http2` cross-check against the real HTTPS listener.
# Extracted from ci.yml's "lyric-web Undertow smoke on JVM
# (tests/jvm_server_smoke.l)" step (#6387/check-workflow-size.sh -- see
# scripts/ci/self-test.sh's header).
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

BUILD_CONFIG="${BUILD_CONFIG:-Debug}"

lyric_bin="bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin; skipping lyric-web JVM smoke"
  exit 1
fi
make maven-resolver
export LYRIC_MAVEN_RESOLVER="$PWD/resolver/target/lyric-resolver.jar"
"$lyric_bin" restore --manifest "$PWD/lyric-web/lyric.toml"
(cd lyric-web && "../$lyric_bin" build --target jvm tests/jvm_server_smoke.l -o /tmp/jvm_server_smoke.jar)
java -jar /tmp/jvm_server_smoke.jar > /tmp/jvm_server_smoke.run.log 2>&1 &
srv_pid=$!
up=0
for _ in $(seq 1 40); do
  if curl -s --max-time 1 -o /dev/null http://localhost:8099/hello/Ada; then up=1; break; fi
  if ! kill -0 "$srv_pid" 2>/dev/null; then break; fi
  sleep 0.5
done
if [ "$up" != 1 ]; then
  echo "::error::jvm_server_smoke server did not come up"
  tail -40 /tmp/jvm_server_smoke.run.log
  exit 1
fi
hello="$(curl -s --max-time 3 http://localhost:8099/hello/Ada)"
header="$(curl -s --max-time 3 -H 'X-Test: abc' http://localhost:8099/echo-header)"
body="$(curl -s --max-time 3 -X POST --data 'ping' http://localhost:8099/echo-body)"
code404="$(curl -s --max-time 3 -o /dev/null -w '%{http_code}' http://localhost:8099/nope)"
# TLS phase 2.2/2.3 (#5881/#6017): before the plaintext listener,
# main runs three in-process self-checks and logs a single
# PASS/FAIL line each:
#   MTLS-MISCONFIG-SELFCHECK — Web.serveTls with
#     requireClientCert=true and NO clientCa must return a typed
#     ServerTlsUnsupported (a genuine misconfiguration — no CA to
#     pin trust to), never a crash or a silent plaintext-auth
#     listener (#6040).
#   HTTPS-H2-SELFCHECK — a TLS-terminated Undertow listener
#     (Web.serveTls, ENABLE_HTTP2) on :8100 driven by an in-process
#     Std.Http client that trusts the fixture cert, asserting 200 AND
#     an h2-negotiated connection (HttpResponse.negotiatedVersion). The
#     client retries in a BOUNDED poll loop until the listener binds
#     (was a fixed sleep that flaked under CI jitter, #6028).
#   MTLS-ACCEPT-SELFCHECK / MTLS-REJECT-SELFCHECK — a REAL mTLS
#     listener on :8102 (clientCa + requireClientCert=true, the
#     client-CA TrustManager + XNIO SSL_CLIENT_AUTH_MODE wiring
#     from #6017): a client presenting a cert signed by the
#     configured CA must connect and get a 200 (ACCEPT), and a
#     client presenting an unrelated self-signed cert must fail
#     the TLS handshake (REJECT) — proving mTLS at the real TLS
#     layer, not just that the config is accepted at the API
#     surface.
# All three self-checks run before the plaintext :8099 listener
# this loop waited on, so the lines are already in the log. An
# independent curl --http2 cross-checks h2 against the real HTTPS
# listener.
h2selfcheck="$(grep -o 'HTTPS-H2-SELFCHECK: PASS.*' /tmp/jvm_server_smoke.run.log | head -1)"
mtlsmisconfigselfcheck="$(grep -o 'MTLS-MISCONFIG-SELFCHECK: PASS.*' /tmp/jvm_server_smoke.run.log | head -1)"
mtlsacceptselfcheck="$(grep -o 'MTLS-ACCEPT-SELFCHECK: PASS.*' /tmp/jvm_server_smoke.run.log | head -1)"
mtlsrejectselfcheck="$(grep -o 'MTLS-REJECT-SELFCHECK: PASS.*' /tmp/jvm_server_smoke.run.log | head -1)"
curlh2="$(curl -sk --http2 --max-time 4 -o /dev/null -w '%{http_version}:%{http_code}' https://127.0.0.1:8100/hello/Ada || echo 'curl-failed')"
kill "$srv_pid" 2>/dev/null || true
wait "$srv_pid" 2>/dev/null || true
fail=0
[ "$hello" = "Hello, Ada!" ] || { echo "::error::hello endpoint returned '$hello'"; fail=1; }
[ "$header" = '{"xTest":"abc"}' ] || { echo "::error::header endpoint returned '$header'"; fail=1; }
[ "$body" = "ping" ] || { echo "::error::body endpoint returned '$body'"; fail=1; }
[ "$code404" = "404" ] || { echo "::error::unmatched route returned HTTP $code404, expected 404"; fail=1; }
[ -n "$h2selfcheck" ] || { echo "::error::HTTPS/h2 in-process self-check did not report PASS (Web.serveTls + negotiatedVersion)"; fail=1; }
[ -n "$mtlsmisconfigselfcheck" ] || { echo "::error::mTLS-misconfig self-check did not report PASS (Web.serveTls requireClientCert with no clientCa -> typed ServerTlsUnsupported)"; fail=1; }
[ -n "$mtlsacceptselfcheck" ] || { echo "::error::mTLS-accept self-check did not report PASS (trusted client cert should connect)"; fail=1; }
[ -n "$mtlsrejectselfcheck" ] || { echo "::error::mTLS-reject self-check did not report PASS (untrusted client cert should be rejected at the TLS layer)"; fail=1; }
[ "$curlh2" = "2:200" ] || { echo "::error::curl --http2 against the TLS listener returned '$curlh2', expected 2:200"; fail=1; }
if [ "$fail" != 0 ]; then
  tail -40 /tmp/jvm_server_smoke.run.log
  exit 1
fi
echo "lyric-web Undertow JVM smoke passed (4/4 plaintext endpoints + HTTPS/h2 serveTls: $h2selfcheck; mTLS-misconfig: $mtlsmisconfigselfcheck; mTLS-accept: $mtlsacceptselfcheck; mTLS-reject: $mtlsrejectselfcheck; curl --http2 $curlh2)" >> "$GITHUB_STEP_SUMMARY"
