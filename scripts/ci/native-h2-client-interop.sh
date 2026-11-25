#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# native-h2-client-interop.sh -- `Std.Http` on --target native against
# independent TLS servers (docs/72 slice 7, D803).
#
#   LYRIC="$lyric_bin" bash scripts/ci/native-h2-client-interop.sh
#
# Starts `nghttpd` (package `nghttp2-server`, installed when it is not on PATH)
# and `openssl s_server -WWW` over one self-signed `localhost` certificate and
# a document root holding `index.html` and a 5 MiB `big.bin`, then runs
# lyric-stdlib/tests/http_client_h2_interop_tests.l with the coordinates in the
# environment. nghttpd selects ALPN h2; `s_server` selects none and answers in
# HTTP/1.x, which is the fallback case.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

lyric_bin="${LYRIC:?set LYRIC to the lyric executable}"

if ! command -v nghttpd >/dev/null 2>&1; then
  sudo rm -f /etc/apt/sources.list.d/google-chrome.list* || true
  sudo apt-get update -qq
  sudo apt-get install -y --no-install-recommends nghttp2-server >/dev/null
fi

work="$(mktemp -d)"
pids=()
cleanup() {
  for pid in "${pids[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
  rm -rf "$work"
}
trap cleanup EXIT

mkdir -p "$work/docroot"
printf 'lyric-h2-interop\n' >"$work/docroot/index.html"
big_bytes=5242880
head -c "$big_bytes" /dev/urandom >"$work/docroot/big.bin"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost" \
  -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null

free_port() {
  python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}
nghttpd_port="$(free_port)"
openssl_port="$(free_port)"

nghttpd -d "$work/docroot" "$nghttpd_port" "$work/key.pem" "$work/cert.pem" >"$work/nghttpd.log" 2>&1 &
pids+=("$!")
(cd "$work/docroot" && exec openssl s_server -accept "$openssl_port" -cert "$work/cert.pem" -key "$work/key.pem" -WWW) \
  >"$work/s_server.log" 2>&1 &
pids+=("$!")
for port in "$nghttpd_port" "$openssl_port"; do
  for _ in $(seq 1 50); do
    (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null && break
    sleep 0.1
  done
done

export LYRIC_NGHTTPD_TLS_PORT="$nghttpd_port"
export LYRIC_OPENSSL_TLS_PORT="$openssl_port"
export LYRIC_NGHTTPD_CERT="$work/cert.pem"
export LYRIC_NGHTTPD_BIG_BYTES="$big_bytes"
"$lyric_bin" test --target native lyric-stdlib/tests/http_client_h2_interop_tests.l
