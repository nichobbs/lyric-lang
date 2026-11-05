#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# async-io-e2e.sh: the async I/O reactor of the native coroutine scheduler (#8494, D405).
#   - the scheduler's C unit tests, which drive the reactor with pipes under both schedulers,
#     plain, under ThreadSanitizer and under AddressSanitizer (`make -C lyric-rt test test-tsan
#     test-asan-async`);
#   - an `async` TCP echo server (lyric-stdlib/tests/async_echo_main.l) with LYRIC_ASYNC_THREADS=2:
#     a client opens 1000 connections, leaves them idle, then sends on every one and checks the
#     echo.  Every idle connection's task must be parked on the reactor, not holding one of the
#     two scheduler threads, or the echoes cannot all come back;
#   - the same server built with ThreadSanitizer and with AddressSanitizer (the generated IR gets
#     `sanitize_thread` / `sanitize_address` on every function, and links the runtime built from
#     source with the sanitizer), with 200 connections.
#
# Usage: LYRIC_BIN=<path to lyric> bash scripts/ci/async-io-e2e.sh
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
: "${LYRIC_BIN:?LYRIC_BIN must name the lyric binary}"
LYRIC_BIN="$(cd "$(dirname "$LYRIC_BIN")" && pwd)/$(basename "$LYRIC_BIN")"

work="$(mktemp -d)"
server_pid=""
cleanup() {
  if [ -n "$server_pid" ]; then kill "$server_pid" 2>/dev/null || true; fi
  rm -rf "$work"
}
trap cleanup EXIT

# The server holds one descriptor per connection, the client another.
ulimit -n 8192 2>/dev/null || ulimit -n "$(ulimit -Hn)"

echo "=== lyric-rt reactor: unit tests, ThreadSanitizer, AddressSanitizer ==="
make -C lyric-rt test test-tsan test-asan-async

cat > "$work/client.py" <<'PY'
import os, socket, sys, time
port_file, count = sys.argv[1], int(sys.argv[2])
deadline = time.time() + 60
while not (os.path.exists(port_file) and open(port_file).read().strip()):
    if time.time() > deadline:
        sys.exit("the server never wrote its port")
    time.sleep(0.05)
port = int(open(port_file).read())
socks = []
for i in range(count):
    s = socket.create_connection(("127.0.0.1", port), timeout=30)
    socks.append(s)
# Every connection is now idle on the server: its task is parked on the reactor.
time.sleep(1.0)
for i, s in enumerate(socks):
    s.sendall(b"ping %d\n" % i)
for i, s in enumerate(socks):
    want = b"ping %d\n" % i
    got = b""
    while len(got) < len(want):
        chunk = s.recv(len(want) - len(got))
        if not chunk:
            sys.exit("connection %d closed before its echo" % i)
        got += chunk
    if got != want:
        sys.exit("connection %d echoed %r, expected %r" % (i, got, want))
for s in socks:
    s.close()
print("client: %d connections echoed" % count)
PY

run_echo() { # binary, connections, threads
  local exe="$1" n="$2" threads="$3"
  rm -f "$work/port"
  LYRIC_ASYNC_THREADS="$threads" LYRIC_ECHO_CONNECTIONS="$n" LYRIC_ECHO_PORT_FILE="$work/port" \
    TSAN_OPTIONS="halt_on_error=1 exitcode=66" "$exe" > "$work/server.out" 2>&1 &
  server_pid=$!
  if ! python3 -I "$work/client.py" "$work/port" "$n"; then
    cat "$work/server.out"
    echo "::error::the echo client failed against $exe"
    exit 1
  fi
  local rc=0
  wait "$server_pid" || rc=$?
  server_pid=""
  cat "$work/server.out"
  if [ "$rc" -ne 0 ] || ! grep -q "^echo ok: $n connections" "$work/server.out"; then
    echo "::error::the echo server exited $rc"
    exit 1
  fi
}

echo "=== async echo server, 1000 idle connections, two scheduler threads ==="
LYRIC_KEEP_LL=1 "$LYRIC_BIN" build --target native lyric-stdlib/tests/async_echo_main.l -o "$work/echo"
run_echo "$work/echo" 1000 2
echo "=== the same, cooperative scheduler ==="
run_echo "$work/echo" 1000 1

[ -f "$work/echo.ll" ] || { echo "::error::LYRIC_KEEP_LL left no IR at $work/echo.ll"; exit 1; }
for san in thread address; do
  echo "=== async echo server under the ${san} sanitizer ==="
  make -C lyric-rt BUILD="build-${san}-io" CFLAGS="-O1 -g -std=c11 -Wall -Wextra -Werror -fPIC -fsanitize=${san}" CC=clang "build-${san}-io/lyric_rt.a"
  sed -E "s/^(define .*\)) ?(#[0-9]+)? ?\{$/\1 \2 sanitize_${san} {/" "$work/echo.ll" > "$work/echo.${san}.ll"
  grep -q "sanitize_${san}" "$work/echo.${san}.ll" || { echo "::error::no function was marked sanitize_${san}"; exit 1; }
  clang -O1 -g "-fsanitize=${san}" -Wno-override-module "$work/echo.${san}.ll" "lyric-rt/build-${san}-io/lyric_rt.a" -lm -lpthread -ldl -o "$work/echo_${san}"
  run_echo "$work/echo_${san}" 200 2
done
echo "async I/O reactor e2e passed"
