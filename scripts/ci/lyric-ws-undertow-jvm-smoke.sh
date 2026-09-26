#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# lyric-ws-undertow-jvm-smoke.sh — lyric-ws Undertow smoke on JVM
# (lyric-ws/tests/ws_jvm_origin_smoke.l).  `Std.TcpHost` has no JVM kernel,
# so the dotnet loopback tests cannot run there; this drives the real
# Undertow WebSocket server from outside instead (#7243):
#   * the Origin policy: cross-origin 403, same-origin / no-Origin 101 on the
#     default server, and a listed origin 101 / unlisted 403 on the server
#     configured with `allowedOrigins`;
#   * handshake headers reaching `onOpen` (the handler logs the User-Agent);
#   * a text message round trip, which exercises the receive listener.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

BUILD_CONFIG="${BUILD_CONFIG:-Debug}"

lyric_bin="bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin; skipping lyric-ws JVM smoke"
  exit 1
fi
# Serialized against the job's other `make maven-resolver` callers (see
# lyric-web-undertow-jvm-smoke.sh).
flock /tmp/lyric-ci-maven-resolver-build.lock -c 'make maven-resolver'
export LYRIC_MAVEN_RESOLVER="$PWD/resolver/target/lyric-resolver.jar"
"$lyric_bin" restore --manifest "$PWD/lyric-ws/lyric.toml"
(cd lyric-ws && "../$lyric_bin" build --target jvm tests/ws_jvm_origin_smoke.l -o /tmp/ws_jvm_origin_smoke.jar)
java -jar /tmp/ws_jvm_origin_smoke.jar > /tmp/ws_jvm_origin_smoke.run.log 2>&1 &
srv_pid=$!
trap 'kill "$srv_pid" 2>/dev/null || true' EXIT
up=0
for _ in $(seq 1 40); do
  if grep -q READY /tmp/ws_jvm_origin_smoke.run.log; then up=1; break; fi
  if ! kill -0 "$srv_pid" 2>/dev/null; then break; fi
  sleep 0.5
done
if [ "$up" != 1 ]; then
  echo "::error::ws_jvm_origin_smoke server did not come up"
  tail -40 /tmp/ws_jvm_origin_smoke.run.log
  exit 1
fi
handshake() {
  curl -s -o /dev/null -w '%{http_code}' --max-time 3 -A "ws-smoke-agent" \
    -H "Connection: Upgrade" -H "Upgrade: websocket" -H "Sec-WebSocket-Version: 13" \
    -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" "$@" || true
}
cross="$(handshake -H 'Origin: https://evil.example' http://127.0.0.1:8111/ws)"
same="$(handshake -H 'Origin: http://127.0.0.1:8111' http://127.0.0.1:8111/ws)"
none="$(handshake http://127.0.0.1:8111/ws)"
listed="$(handshake -H 'Origin: https://APP.example.com' http://127.0.0.1:8112/ws)"
unlisted="$(handshake -H 'Origin: https://evil.example' http://127.0.0.1:8112/ws)"
echo="$(python3 - <<'PY' || true
import os, socket
s = socket.create_connection(("127.0.0.1", 8111), timeout=5)
s.sendall(b"GET /ws HTTP/1.1\r\nHost: 127.0.0.1:8111\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
          b"Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n")
buf = b""
while b"\r\n\r\n" not in buf:
    buf += s.recv(4096)
head, rest = buf.split(b"\r\n\r\n", 1)
if b" 101 " not in head.split(b"\r\n")[0]:
    raise SystemExit("handshake not upgraded: " + head.decode(errors="replace"))
payload = b"hello"
mask = os.urandom(4)
s.sendall(bytes([0x81, 0x80 | len(payload)]) + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))
while len(rest) < 2:
    rest += s.recv(4096)
n = rest[1] & 0x7F
while len(rest) < 2 + n:
    rest += s.recv(4096)
print(rest[2:2 + n].decode())
PY
)"
sleep 0.5
fail=0
[ "$cross" = "403" ] || { echo "::error::cross-origin handshake returned HTTP $cross, expected 403"; fail=1; }
[ "$same" = "101" ] || { echo "::error::same-origin handshake returned HTTP $same, expected 101"; fail=1; }
[ "$none" = "101" ] || { echo "::error::handshake without Origin returned HTTP $none, expected 101"; fail=1; }
[ "$listed" = "101" ] || { echo "::error::allowedOrigins handshake returned HTTP $listed, expected 101"; fail=1; }
[ "$unlisted" = "403" ] || { echo "::error::unlisted origin returned HTTP $unlisted, expected 403"; fail=1; }
grep -q "OPEN user-agent=ws-smoke-agent" /tmp/ws_jvm_origin_smoke.run.log ||
  { echo "::error::handshake headers did not reach onOpen"; fail=1; }
[ "$echo" = "echo:hello" ] || { echo "::error::text round trip returned '$echo', expected 'echo:hello'"; fail=1; }
if grep -q "AbstractMethodError\|NoClassDefFoundError" /tmp/ws_jvm_origin_smoke.run.log; then
  echo "::error::the server logged a linkage error"
  fail=1
fi
if [ "$fail" != 0 ]; then
  tail -40 /tmp/ws_jvm_origin_smoke.run.log
  exit 1
fi
echo "lyric-ws Undertow JVM smoke passed (Origin policy 5/5, onOpen headers, text round trip)" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
