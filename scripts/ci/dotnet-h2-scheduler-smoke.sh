#!/usr/bin/env bash
# Cross-checks the dotnet Std.HttpServer h2 send scheduler (#6107) with curl, an
# independent HTTP/2 client, against a running lyric-stdlib/tests/dotnet_h2_smoke.l
# server: concurrent streams do not queue behind a slow handler, chunked
# responses reach the client per chunk, and a stream the client resets aborts the
# handler's writes.
#
#   dotnet-h2-scheduler-smoke.sh <base-url> <server-log>
set -euo pipefail

base="$1"
server_log="$2"

# 1. A slow and a fast request multiplexed on one connection: the fast one must
#    finish well before the slow one's two seconds.
times="$(curl -sk --http2 --parallel --parallel-immediate \
  -o /dev/null "$base/slow" -o /dev/null "$base/fast" -w '%{url_effective} %{time_total}\n')"
fast_ms="$(echo "$times" | awk '/\/fast/ {printf "%d", $2 * 1000}')"
slow_ms="$(echo "$times" | awk '/\/slow/ {printf "%d", $2 * 1000}')"
if [ -z "$fast_ms" ] || [ -z "$slow_ms" ] || [ "$fast_ms" -ge 1000 ] || [ "$slow_ms" -lt 1800 ]; then
  echo "::error::h2 streams were not served concurrently (fast=${fast_ms}ms slow=${slow_ms}ms)"
  exit 1
fi

# 2. A chunked response whose second chunk is held back 1.5 s: the first line
#    must arrive at least one second before the second.
stamps="$(curl -sk --http2 -N --max-time 8 "$base/stream" | while IFS= read -r line; do echo "$(date +%s%3N) $line"; done)"
t_first="$(echo "$stamps" | awk '/first/ {print $1}')"
t_second="$(echo "$stamps" | awk '/second/ {print $1}')"
if [ -z "$t_first" ] || [ -z "$t_second" ] || [ $((t_second - t_first)) -lt 1000 ]; then
  echo "::error::h2 chunked response was not streamed incrementally (first=$t_first second=$t_second)"
  exit 1
fi

# 3. A client that sends its request and then half-closes its write side must
#    still receive the response a handler is producing (#8683): /slow answers
#    two seconds after the FIN, so the connection has to drain, not close.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! half_close="$(python3 -I "$here/h2-half-close-client.py" "$base" /slow slow)"; then
  echo "::error::a response in flight was lost when the h2 client half-closed: $half_close"
  exit 1
fi

# 4. The client resets an endless stream after a second: the handler's next
#    chunk write must fail rather than block or spin forever.
curl -sk --http2 --max-time 1 -o /dev/null "$base/endless" || true
for _ in $(seq 1 25); do
  if grep -q DOTNET-H2-SMOKE-STREAM-ABORTED "$server_log"; then
    echo "dotnet Std.HttpServer h2 scheduler smoke passed (fast=${fast_ms}ms slow=${slow_ms}ms, chunk gap=$((t_second - t_first))ms, half-close: $half_close)"
    exit 0
  fi
  sleep 0.2
done
echo "::error::the handler was not told its h2 stream was reset"
exit 1
