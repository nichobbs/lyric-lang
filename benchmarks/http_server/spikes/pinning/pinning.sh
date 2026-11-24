#!/usr/bin/env bash
# SPIKE (docs/73 S0 spike b), not shipped. Checks that JDK 21 virtual threads blocked in an SSLSocket read
# are parked, not pinned, through the existing Std.TcpHost TLS path.
#
# Two runs of tls_echo_server.l on --target jvm against 32 concurrent TLS clients:
#   1. default scheduler with -Djdk.tracePinnedThreads=full: any pinned park prints a stack to stdout;
#   2. a one-carrier scheduler (parallelism=1, maxPoolSize=1): if a blocked SSLSocket read pinned its carrier,
#      the only carrier would be stuck on the first connection and the other clients would time out.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../../.."
LYRIC="${LYRIC:-./bin/lyric}"
OUT="${OUT:-$(mktemp -d)}"; mkdir -p "$OUT"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$OUT/key.pem" -out "$OUT/cert.pem" -days 2 \
  -subj "/CN=localhost" -addext "subjectAltName=IP:127.0.0.1" 2>/dev/null
"$LYRIC" build --target jvm benchmarks/http_server/spikes/pinning/tls_echo_server.l -o "$OUT/tls_echo.jar"
run() { # name, extra java flags
  local name="$1"; shift
  SPIKE_PORT=9443 SPIKE_CERT="$OUT/cert.pem" SPIKE_KEY="$OUT/key.pem" java "$@" -jar "$OUT/tls_echo.jar" > "$OUT/$name.log" 2>&1 &
  local pid=$!
  for _ in $(seq 1 60); do grep -q listening "$OUT/$name.log" 2>/dev/null && break; sleep 0.5; done
  python3 -I benchmarks/http_server/spikes/pinning/client.py 9443 32 3 | tee "$OUT/$name.client"
  kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
  echo "$name: pinned-thread stack traces in server output: $(grep -c 'reason:\|<== BLOCKED\|pinned' "$OUT/$name.log" || true)"
}
run default -Djdk.tracePinnedThreads=full
run onecarrier -Djdk.virtualThreadScheduler.parallelism=1 -Djdk.virtualThreadScheduler.maxPoolSize=1 -Djdk.tracePinnedThreads=full
echo "logs in $OUT"
