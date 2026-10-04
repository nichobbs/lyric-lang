#!/usr/bin/env bash
# Build examples/native-web with --target native, run it, and exercise
# HTTP routes plus a WebSocket echo over a raw RFC 6455 client.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD_CONFIG="${BUILD_CONFIG:-Debug}"
LYRIC="${LYRIC:-$ROOT/bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric}"
[ -x "$LYRIC" ] || LYRIC="$ROOT/bin/lyric"
[ -x "$LYRIC" ] || { echo "::error::lyric binary not found"; exit 1; }
OUT="${TMPDIR:-/tmp}/native-web-smoke"
PORT=18480

"$LYRIC" build --manifest "$ROOT/examples/native-web/lyric.toml" --target native -o "$OUT"
"$OUT" &
PID=$!
trap 'kill $PID 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do curl -sf "http://127.0.0.1:$PORT/" >/dev/null && break; sleep 0.2; done

expect() { [ "$1" = "$2" ] || { echo "FAIL: expected '$2' got '$1'"; exit 1; }; }
expect "$(curl -s http://127.0.0.1:$PORT/)" "hello native"
expect "$(curl -s http://127.0.0.1:$PORT/echo/abc)" "echo:abc"
expect "$(curl -s -X POST -d payload http://127.0.0.1:$PORT/post)" "post:payload"
expect "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$PORT/nope)" "404"

python3 - "$PORT" <<'PY'
import base64, os, socket, struct, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=5)
key = base64.b64encode(os.urandom(16)).decode()
s.sendall((f"GET /live HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
           f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
buf = b""
while b"\r\n\r\n" not in buf:
    buf += s.recv(4096)
assert buf.startswith(b"HTTP/1.1 101"), buf
msg = b"ping"; mask = os.urandom(4)
s.sendall(bytes([0x81, 0x80 | len(msg)]) + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(msg)))
hdr = s.recv(2)
n = hdr[1] & 0x7f
body = b""
while len(body) < n:
    body += s.recv(n - len(body))
assert body, "empty echo"
print("ws echo:", body)
PY
echo "native-web smoke OK"
