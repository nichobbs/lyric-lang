#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# smtp-roundtrip-e2e.sh: lyric-mail's SMTP sender delivers real messages to a
# local SMTP server, on both targets (#7462).  The server is
# scripts/ci/smtp_capture_server.py; mail_tests.l's gated round-trip tests send
# through `Mail.connectSmtp()` (System.Net.Mail on dotnet, Jakarta Mail on jvm)
# and scripts/ci/smtp_verify.py checks the wire messages the server captured
# (envelope, headers, subject, MIME structure, attachment); this script also
# checks that an unreachable server and bad credentials are errors.
#
#   bash scripts/ci/smtp-roundtrip-e2e.sh [dotnet] [jvm]
# LYRIC_BIN overrides the binary (default: the AOT build for BUILD_CONFIG).
# On jvm, LYRIC_MAVEN_RESOLVER must name lyric-resolver.jar (make maven-resolver).
# ---------------------------------------------------------------------------
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
BUILD_CONFIG="${BUILD_CONFIG:-Debug}"
lyric_bin="${LYRIC_BIN:-bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric}"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::lyric binary not found at $lyric_bin" >&2
  exit 1
fi
targets=("$@")
if [ ${#targets[@]} -eq 0 ]; then targets=(dotnet jvm); fi

work="$(mktemp -d)"
server_pid=""
cleanup() {
  [ -n "$server_pid" ] && kill "$server_pid" 2>/dev/null
  rm -rf "$work"
}
trap cleanup EXIT

fail=0
if printf '%s' "${targets[*]}" | grep -q jvm; then
  "$lyric_bin" restore --manifest lyric-mail/lyric.toml || { echo "FAIL: lyric-mail restore"; exit 1; }
fi

for target in "${targets[@]}"; do
  out="$work/$target"
  mkdir -p "$out"
  python3 scripts/ci/smtp_capture_server.py "$out" --user ci-user --password ci-secret &
  server_pid=$!
  for _ in $(seq 1 50); do [ -s "$out/port" ] && break; sleep 0.1; done
  if [ ! -s "$out/port" ]; then echo "FAIL: capture server did not start"; exit 1; fi
  port="$(cat "$out/port")"

  export LYRIC_CONFIG_SMTP_HOST=127.0.0.1 LYRIC_CONFIG_SMTP_PORT="$port"
  export LYRIC_CONFIG_SMTP_USERNAME=ci-user LYRIC_CONFIG_SMTP_PASSWORD=ci-secret
  export LYRIC_CONFIG_SMTP_USETLS=false LYRIC_CONFIG_SMTP_TIMEOUTMS=15000
  export LYRIC_MAIL_TEST_ROUNDTRIP=1
  echo "=== SMTP round trip, --target $target (server on port $port) ==="
  log="$work/$target.log"
  if ! "$lyric_bin" test --target "$target" --manifest lyric-mail/lyric.toml >"$log" 2>&1; then
    echo "FAIL: lyric test --target $target"; tail -40 "$log"; fail=1
  fi
  unset LYRIC_MAIL_TEST_ROUNDTRIP

  if ! python3 scripts/ci/smtp_verify.py "$out"; then
    echo "--- server log / captured messages for --target $target:"; tail -30 "$log"; fail=1
  fi

  # A server that is not listening is a SEND_ERROR, never a crash.
  LYRIC_CONFIG_SMTP_PORT=1 LYRIC_CONFIG_SMTP_TIMEOUTMS=3000 LYRIC_MAIL_TEST_UNREACHABLE=1 \
    "$lyric_bin" test --target "$target" --manifest lyric-mail/lyric.toml >"$work/$target-unreachable.log" 2>&1 || {
    echo "FAIL: unreachable-server test --target $target"; tail -30 "$work/$target-unreachable.log"; fail=1; }

  # Rejected credentials come back as an error and deliver nothing.
  before=$(ls "$out"/*.eml | wc -l)
  LYRIC_CONFIG_SMTP_PASSWORD=wrong LYRIC_MAIL_TEST_ROUNDTRIP=1 \
    "$lyric_bin" test --target "$target" --manifest lyric-mail/lyric.toml >"$work/$target-badauth.log" 2>&1 && {
    echo "FAIL: --target $target accepted wrong credentials"; fail=1; }
  after=$(ls "$out"/*.eml | wc -l)
  if [ "$before" -ne "$after" ]; then echo "FAIL: --target $target delivered mail with wrong credentials"; fail=1; fi

  kill "$server_pid" 2>/dev/null; server_pid=""
done

[ "$fail" -eq 0 ] && echo "lyric-mail SMTP round trip (${targets[*]}): ok"
exit "$fail"
