#!/usr/bin/env bash
# SPIKE (docs/73 S0 spike c), not shipped. Tries to reproduce the "cross-error-type nested match" JVM miscompile that
# lyric-web/src/web.l (~2455) documents: a Result[_, E1] from another package matched inside a function that returns
# Result[_, E2], where the backend was said to cast the inner Err payload to E2 (ClassCastException, the #5903 family).
#   1. serve_tls_repro.l: the exact shape of the shared `Web.serveTls` against the real Std.HttpServer types;
#   2. twopkg/: the same shape with two user packages, matching `e` by `ListenError.message`, by case, and as a nested pattern.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../../../.."
LYRIC="$(realpath "${LYRIC:-./bin/lyric}")"
OUT="${OUT:-$(mktemp -d)}"; mkdir -p "$OUT"
HERE=benchmarks/http_server/spikes/crosserror
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$OUT/key.pem" -out "$OUT/cert.pem" -days 2 -subj "/CN=localhost" 2>/dev/null
cp "$HERE/serve_tls_repro.l" "$OUT/"
( cd "$OUT" && "$LYRIC" build --target jvm serve_tls_repro.l -o repro.jar >/dev/null 2>&1 && java -jar repro.jar 2>&1 | grep -v Picked )
cp -r "$HERE/twopkg" "$OUT/twopkg"
( cd "$OUT/twopkg" && "$LYRIC" build --target jvm src/main.l -o repro.jar >/dev/null 2>&1 && java -jar repro.jar 2>&1 | grep -v Picked )
