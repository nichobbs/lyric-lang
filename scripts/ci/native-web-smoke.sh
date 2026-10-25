#!/usr/bin/env bash
# Build examples/native-web with --target native, run it, and exercise
# HTTP routes, the static-file root check against symlinks that leave the
# root (#8507), and a WebSocket echo over a raw RFC 6455 client.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD_CONFIG="${BUILD_CONFIG:-Debug}"
LYRIC="${LYRIC:-$ROOT/bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric}"
[ -x "$LYRIC" ] || LYRIC="$ROOT/bin/lyric"
[ -x "$LYRIC" ] || { echo "::error::lyric binary not found"; exit 1; }
# A private lyric_rt.a: this step runs in the background beside other
# native steps, so the dev tree's lyric-rt/build may not exist yet or may be
# mid-rebuild when the link runs.
rt_build_dir="$(mktemp -d)/lyric-rt-build"
make -C "$ROOT/lyric-rt" BUILD="$rt_build_dir"
export LYRIC_RT_PATH="$rt_build_dir/lyric_rt.a"
OUT="${TMPDIR:-/tmp}/native-web-smoke"
PORT=18480

"$LYRIC" build --manifest "$ROOT/examples/native-web/lyric.toml" --target native -o "$OUT"

# The static root is ./public under the server's working directory.  Every
# link below except the in-root chains points (or climbs) outside it.
SITE="$(mktemp -d)"
mkdir -p "$SITE/public" "$SITE/outside"
printf 'fine to serve' > "$SITE/public/ok.txt"
printf 'top secret' > "$SITE/secret.txt"
printf 'outside inner' > "$SITE/outside/inner.txt"
ln -s "$SITE/secret.txt" "$SITE/public/link.txt"
ln -s "$SITE/outside" "$SITE/public/linkdir"
ln -s ../secret.txt "$SITE/public/hop2"
ln -s hop2 "$SITE/public/hop1"
ln -s ok.txt "$SITE/public/inner2"
ln -s inner2 "$SITE/public/inner1"
ln -s loopb "$SITE/public/loopa"
ln -s loopa "$SITE/public/loopb"
chain() {
  local prefix=$1 count=$2 i
  for ((i = 0; i < count; i++)); do
    if ((i == count - 1)); then ln -s ok.txt "$SITE/public/$prefix$i"; else ln -s "$prefix$((i + 1))" "$SITE/public/$prefix$i"; fi
  done
}
chain short 30
chain long 45

(cd "$SITE" && exec "$OUT") &
PID=$!
trap 'kill $PID 2>/dev/null || true; rm -rf "$SITE"' EXIT
ready=0
for _ in $(seq 1 50); do
  if curl -sf "http://127.0.0.1:$PORT/" >/dev/null; then ready=1; break; fi
  kill -0 $PID 2>/dev/null || { echo "FAIL: server exited before becoming ready"; exit 1; }
  sleep 0.2
done
[ "$ready" = 1 ] || { echo "FAIL: server not ready on port $PORT after 10s"; exit 1; }

expect() { [ "$1" = "$2" ] || { echo "FAIL: expected '$2' got '$1'"; exit 1; }; }
expect "$(curl -s http://127.0.0.1:$PORT/)" "hello native"
expect "$(curl -s http://127.0.0.1:$PORT/echo/abc)" "echo:abc"
expect "$(curl -s -X POST -d payload http://127.0.0.1:$PORT/post)" "post:payload"
expect "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$PORT/nope)" "404"

status() { curl -s --path-as-is -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT$1"; }
expect "$(curl -s http://127.0.0.1:$PORT/static/ok.txt)" "fine to serve"
expect "$(status /static/inner1)" "200"
expect "$(status /static/short0)" "200"
for path in /static/link.txt /static/linkdir/inner.txt /static/linkdir/../secret.txt /static/hop1 \
  /static/loopa /static/long0 /static/../secret.txt /static/missing.txt /static/linkdir/missing.txt; do
  expect "$(status "$path")" "404"
done

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
assert body == b"echo:ping", body
print("ws echo:", body)
PY
echo "native-web smoke OK"
