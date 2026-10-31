#!/usr/bin/env bash
# Builds and runs lyric-stdlib/tests/dotnet_h2_smoke.l (the dotnet Std.HttpServer
# h2 smoke server) and probes it with curl --http2, an independent client:
# negotiation (2:200) and the send-scheduler checks (#6107, see
# dotnet-h2-scheduler-smoke.sh). Appends its result to $GITHUB_STEP_SUMMARY.
#
# Kept out of ci.yml, which has a size ceiling (scripts/ci/check-workflow-size.sh).
set -euo pipefail

lyric_bin="bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
log=/tmp/dotnet_h2_smoke.run.log
base=https://127.0.0.1:8443

if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin; skipping dotnet h2 curl smoke"
  exit 1
fi
"$lyric_bin" build --target dotnet lyric-stdlib/tests/dotnet_h2_smoke.l -o /tmp/dotnet_h2_smoke.dll
dotnet /tmp/dotnet_h2_smoke.dll > "$log" 2>&1 &
smoke_pid=$!
trap 'kill "$smoke_pid" 2>/dev/null || true' EXIT

up=0
for _ in $(seq 1 50); do
  if curl -sk --http2 --max-time 1 -o /dev/null "$base/hello" 2>/dev/null; then up=1; break; fi
  if ! kill -0 "$smoke_pid" 2>/dev/null; then break; fi
  sleep 0.2
done
if [ "$up" != "1" ]; then
  echo "::error::dotnet_h2_smoke server did not come up"
  cat "$log" || true
  exit 1
fi

# -o /dev/null so the output is only the -w text (`2:200`), not the body.
curlh2="$(curl -sk -o /dev/null --http2 --max-time 4 -w '%{http_version}:%{http_code}' "$base/hello" || echo 'curl-failed')"
if [ "$curlh2" != "2:200" ]; then
  echo "::error::curl --http2 against the dotnet TLS listener returned '$curlh2', expected 2:200"
  cat "$log" || true
  exit 1
fi
echo "dotnet Std.HttpServer h2 curl --http2 smoke passed ($curlh2)" >> "$summary"

if ! bash scripts/ci/dotnet-h2-scheduler-smoke.sh "$base" "$log" >> "$summary"; then
  cat "$log" || true
  exit 1
fi
