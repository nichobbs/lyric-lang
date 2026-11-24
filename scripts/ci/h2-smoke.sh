#!/usr/bin/env bash
# Builds and runs lyric-stdlib/tests/h2_smoke.l (the Std.HttpServer h2 smoke
# server) for one target and probes it with curl --http2, an independent client:
# negotiation (2:200) and the send-scheduler checks (#6107, see
# h2-scheduler-smoke.sh). Appends its result to $GITHUB_STEP_SUMMARY.
#
#   h2-smoke.sh dotnet|jvm|native
#
# Kept out of ci.yml, which has a size ceiling (scripts/ci/check-workflow-size.sh).
set -euo pipefail

target="${1:?usage: h2-smoke.sh dotnet|jvm|native}"
lyric_bin="${LYRIC:-bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG:-Debug}/lyric}"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
out="$(mktemp -d)"
log="$out/h2_smoke.run.log"
base=https://127.0.0.1:8443

if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin; skipping $target h2 curl smoke"
  exit 1
fi
case "$target" in
  dotnet)
    "$lyric_bin" build --target dotnet lyric-stdlib/tests/h2_smoke.l -o "$out/h2_smoke.dll"
    dotnet "$out/h2_smoke.dll" > "$log" 2>&1 &
    ;;
  jvm)
    "$lyric_bin" build --target jvm lyric-stdlib/tests/h2_smoke.l -o "$out/h2_smoke.jar"
    java -jar "$out/h2_smoke.jar" > "$log" 2>&1 &
    ;;
  native)
    "$lyric_bin" build --target native lyric-stdlib/tests/h2_smoke.l -o "$out/h2_smoke"
    "$out/h2_smoke" > "$log" 2>&1 &
    ;;
  *) echo "unknown target $target" >&2; exit 1 ;;
esac
smoke_pid=$!
trap 'kill "$smoke_pid" 2>/dev/null || true; rm -rf "$out"' EXIT

up=0
for _ in $(seq 1 50); do
  if curl -sk --http2 --max-time 1 -o /dev/null "$base/hello" 2>/dev/null; then up=1; break; fi
  if ! kill -0 "$smoke_pid" 2>/dev/null; then break; fi
  sleep 0.2
done
if [ "$up" != "1" ]; then
  echo "::error::h2_smoke server ($target) did not come up"
  cat "$log" || true
  exit 1
fi

# -o /dev/null so the output is only the -w text (`2:200`), not the body.
curlh2="$(curl -sk -o /dev/null --http2 --max-time 4 -w '%{http_version}:%{http_code}' "$base/hello" || echo 'curl-failed')"
if [ "$curlh2" != "2:200" ]; then
  echo "::error::curl --http2 against the $target TLS listener returned '$curlh2', expected 2:200"
  cat "$log" || true
  exit 1
fi
echo "$target Std.HttpServer h2 curl --http2 smoke passed ($curlh2)" >> "$summary"

# An HTTP/1.1-only client must still be served on the same listener, and a burst
# of multiplexed requests (when h2load is installed) must not lose one.
curlh1="$(curl -sk -o /dev/null --http1.1 --max-time 4 -w '%{http_version}:%{http_code}' "$base/hello" || echo 'curl-failed')"
if [ "$curlh1" != "1.1:200" ]; then
  echo "::error::curl --http1.1 against the $target TLS listener returned '$curlh1', expected 1.1:200"
  cat "$log" || true
  exit 1
fi
if command -v h2load >/dev/null 2>&1; then
  load="$(h2load -n 20000 -c 8 -m 10 "$base/hello" 2>&1 || true)"
  if ! echo "$load" | grep -q "requests: 20000 total, 20000 started, 20000 done, 20000 succeeded, 0 failed, 0 errored"; then
    echo "::error::h2load against the $target listener lost requests"
    echo "$load" | grep -E "requests:|status codes" || true
    exit 1
  fi
fi

# tee, not a bare redirect: the scheduler smoke reports a failed check as an
# ::error:: line on stdout, which must reach the job log and not only the step summary.
if ! bash scripts/ci/h2-scheduler-smoke.sh "$base" "$log" | tee -a "$summary"; then
  cat "$log" || true
  exit 1
fi
