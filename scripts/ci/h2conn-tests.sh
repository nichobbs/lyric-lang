#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# h2conn-tests.sh — run the Std.HttpEngine h2 corpora on one target.
#
#   bash scripts/ci/h2conn-tests.sh dotnet|jvm
#
# Runs the server-role corpus (http_h2conn_tests.l), the client-role corpus with
# its loopback and negative matrix (http_h2conn_client_tests.l), the client
# driver corpus (http_h2client_tests.l: scripted peers, the real Std.HttpServer
# over TLS) and the interop corpus (http_h2client_interop_tests.l, the driver
# against `nghttpd` over h2c and TLS+ALPN) through self-test.sh, so a single
# ci.yml step covers all of them and the workflow file does not grow (see
# self-test.sh for the size-limit rationale).
#
# nghttpd comes from the `nghttp2-server` package (installed here when it is not
# on PATH). It serves a document root with `index.html` and `big.bin`; the
# certificate is generated per run and is the client's only trust anchor.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

target="${1:-}"
case "$target" in
  dotnet | jvm) ;;
  *)
    echo "::error::h2conn-tests.sh: expected 'dotnet' or 'jvm', got '${target}'" >&2
    exit 2
    ;;
esac

for test_file in http_h2conn_tests.l http_h2conn_client_tests.l http_h2client_tests.l; do
  bash scripts/ci/self-test.sh \
    --summary "Std.HttpEngine.H2Conn test ran: ${test_file} (--target ${target})" \
    --target "$target" "lyric-stdlib/tests/${test_file}"
done

if ! command -v nghttpd >/dev/null 2>&1; then
  sudo rm -f /etc/apt/sources.list.d/google-chrome.list* || true
  sudo apt-get update -qq
  sudo apt-get install -y --no-install-recommends nghttp2-server >/dev/null
fi

work="$(mktemp -d)"
nghttpd_pids=()
cleanup() {
  for pid in "${nghttpd_pids[@]:-}"; do
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
h2c_port="$(free_port)"
tls_port="$(free_port)"

nghttpd --no-tls -d "$work/docroot" "$h2c_port" >"$work/nghttpd-h2c.log" 2>&1 &
nghttpd_pids+=("$!")
nghttpd -d "$work/docroot" "$tls_port" "$work/key.pem" "$work/cert.pem" >"$work/nghttpd-tls.log" 2>&1 &
nghttpd_pids+=("$!")
for port in "$h2c_port" "$tls_port"; do
  for _ in $(seq 1 50); do
    (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null && break
    sleep 0.1
  done
done

export LYRIC_NGHTTPD_H2C_PORT="$h2c_port"
export LYRIC_NGHTTPD_TLS_PORT="$tls_port"
export LYRIC_NGHTTPD_CERT="$work/cert.pem"
export LYRIC_NGHTTPD_BIG_BYTES="$big_bytes"
bash scripts/ci/self-test.sh \
  --summary "Std.HttpEngine.H2Client interop ran against nghttpd: http_h2client_interop_tests.l (--target ${target})" \
  --target "$target" lyric-stdlib/tests/http_h2client_interop_tests.l
