#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# run-single-file-examples.sh — run/test single-file examples to catch
# runtime regressions (csv/fizzbuzz/primes/wordcount/ffi_bcl/ffi_datetime,
# examples/rest_service.l HTTP smoke, lyric-web/tests/serve_failure_tests.l
# per-request crash isolation, lyric-web/tests/streaming_tests.l chunked
# streaming). Extracted from ci.yml's "Run single-file examples" step
# (#6387/check-workflow-size.sh — see scripts/ci/self-test.sh's header).
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

BUILD_CONFIG="${BUILD_CONFIG:-Debug}"

lyric_bin="bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric"
if [ ! -x "$lyric_bin" ]; then
  echo "::warning::AOT binary not found; skipping example runs"
  exit 0
fi
# Run-to-completion examples (assert exit 0).
for ex in csv fizzbuzz primes wordcount ffi_bcl ffi_datetime; do
  echo "=== run examples/$ex.l ==="
  "$lyric_bin" run "examples/$ex.l" > /tmp/"$ex".run.log 2>&1 \
    && echo "PASS" || { echo "FAIL"; tail -10 /tmp/"$ex".run.log; exit 1; }
done
# rest_service starts an HTTP listener and runs until killed.  Run it
# in the background, wait for the "Listening on" line in its log,
# smoke-test the endpoint, then SIGTERM the server.
echo "=== smoke examples/rest_service.l ==="
"$lyric_bin" run examples/rest_service.l > /tmp/rest_service.run.log 2>&1 &
srv_pid=$!
for _ in $(seq 1 20); do
  if grep -q "Listening on" /tmp/rest_service.run.log 2>/dev/null; then
    break
  fi
  sleep 0.5
done
if ! kill -0 "$srv_pid" 2>/dev/null; then
  echo "FAIL: rest_service exited before serving"
  tail -20 /tmp/rest_service.run.log
  exit 1
fi
body="$(curl -s --max-time 3 http://localhost:8080/ || true)"
kill "$srv_pid" 2>/dev/null || true
wait "$srv_pid" 2>/dev/null || true
if [ "$body" != "Hello from Lyric!" ]; then
  echo "FAIL: unexpected body '$body'"
  tail -20 /tmp/rest_service.run.log
  exit 1
fi
echo "PASS"
# Web.serve() per-request crash isolation (#5261, supersedes the
# #5260 fail-fast contract): the server's /crash route panics during
# request handling; serve()'s per-request catch-Bug arm must log the
# [lyric-web] failure line, answer that request 500, and KEEP the
# accept loop running — a single bad request must not take the whole
# server down. Assert /crash -> 500, the failure line is logged, and
# /health still serves 200 afterward; then kill the server (it no
# longer exits on its own).
echo "=== smoke lyric-web/tests/serve_failure_tests.l ==="
"$lyric_bin" run lyric-web/tests/serve_failure_tests.l > /tmp/serve_failure.run.log 2>&1 &
sf_pid=$!
for _ in $(seq 1 20); do
  if curl -s --max-time 1 http://127.0.0.1:8199/health >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done
if ! kill -0 "$sf_pid" 2>/dev/null; then
  echo "FAIL: serve_failure server exited before serving"
  tail -20 /tmp/serve_failure.run.log
  exit 1
fi
sf_crash_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 http://127.0.0.1:8199/crash || echo "000")
if [ "$sf_crash_code" != "500" ]; then
  echo "FAIL: /crash returned '$sf_crash_code', expected 500 (#5261)"
  kill "$sf_pid" 2>/dev/null || true
  tail -20 /tmp/serve_failure.run.log
  exit 1
fi
if ! grep -q "\[lyric-web\] request handling failed" /tmp/serve_failure.run.log; then
  echo "FAIL: missing [lyric-web] failure line in serve_failure log (#5261)"
  kill "$sf_pid" 2>/dev/null || true
  tail -20 /tmp/serve_failure.run.log
  exit 1
fi
sf_health_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 3 http://127.0.0.1:8199/health || echo "000")
if [ "$sf_health_code" != "200" ]; then
  echo "FAIL: /health returned '$sf_health_code' after a request-handler panic; server did not survive (#5261)"
  kill "$sf_pid" 2>/dev/null || true
  tail -20 /tmp/serve_failure.run.log
  exit 1
fi
kill "$sf_pid" 2>/dev/null || true
wait "$sf_pid" 2>/dev/null || true
echo "PASS"
# Web.serveStreaming()/ResponseWriter (lyric-lang#5979): a chunk
# written before the handler finishes must reach the client before
# the handler produces the next one -- not be buffered until the
# whole response is done. /stream sleeps 400ms between its two
# chunks; time the request and require it took at least that long
# (a buffered/instant response would come back near-instantly).
echo "=== smoke lyric-web/tests/streaming_tests.l ==="
"$lyric_bin" run lyric-web/tests/streaming_tests.l > /tmp/streaming.run.log 2>&1 &
st_pid=$!
for _ in $(seq 1 20); do
  if curl -s --max-time 1 http://127.0.0.1:8210/health >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done
if ! kill -0 "$st_pid" 2>/dev/null; then
  echo "FAIL: streaming_tests server exited before serving"
  tail -20 /tmp/streaming.run.log
  exit 1
fi
stream_start=$(date +%s%N)
curl -sN --max-time 5 -D /tmp/stream_headers.txt -o /tmp/stream_body.txt http://127.0.0.1:8210/stream
stream_end=$(date +%s%N)
stream_ms=$(( (stream_end - stream_start) / 1000000 ))
if [ "$stream_ms" -lt 350 ]; then
  echo "FAIL: /stream returned in ${stream_ms}ms, expected >= 400ms (chunks were buffered, not streamed)"
  cat /tmp/stream_headers.txt
  exit 1
fi
if ! grep -q "chunk0" /tmp/stream_body.txt || ! grep -q "chunk1" /tmp/stream_body.txt; then
  echo "FAIL: /stream body missing expected chunk markers"
  cat /tmp/stream_body.txt
  exit 1
fi
if ! grep -qi "Transfer-Encoding: *chunked" /tmp/stream_headers.txt; then
  echo "FAIL: /stream response missing Transfer-Encoding: chunked"
  cat /tmp/stream_headers.txt
  exit 1
fi
if grep -qi "Content-Length" /tmp/stream_headers.txt; then
  echo "FAIL: /stream response set Content-Length (chunked responses must not need one up front)"
  cat /tmp/stream_headers.txt
  exit 1
fi
empty_body="$(curl -s --max-time 3 http://127.0.0.1:8210/empty || true)"
if [ -n "$empty_body" ]; then
  echo "FAIL: /empty (handler that never calls writeChunk) returned a non-empty body: '$empty_body'"
  exit 1
fi
created_status="$(curl -s --max-time 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:8210/created || true)"
if [ "$created_status" != "201" ]; then
  echo "FAIL: /created (writeStatus(w, 201)) returned status '$created_status', expected 201"
  exit 1
fi
# BlockingMiddleware (lyric-lang#5985): a streaming route's middleware
# must run and be able to reject the request before the streaming
# handler is ever invoked -- a 403 here (not a crash from
# NeverRunHandler's panic) proves streaming dispatch goes through
# router.middlewares.
blocked_status="$(curl -s --max-time 3 -o /tmp/blocked_body.txt -w '%{http_code}' http://127.0.0.1:8210/blocked || true)"
if [ "$blocked_status" != "403" ]; then
  echo "FAIL: /blocked returned status '$blocked_status', expected 403 (BlockingMiddleware should reject before the streaming handler runs)"
  cat /tmp/blocked_body.txt
  exit 1
fi
if ! kill -0 "$st_pid" 2>/dev/null; then
  echo "FAIL: streaming_tests server crashed handling /blocked (NeverRunHandler's panic ran -- middleware did not block it)"
  tail -20 /tmp/streaming.run.log
  exit 1
fi
kill "$st_pid" 2>/dev/null || true
wait "$st_pid" 2>/dev/null || true
echo "PASS"

