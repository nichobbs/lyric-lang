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
# STARTTLS (#8573): the same messages go through a capture server started with
# --tls and a certificate made for this run, with LYRIC_CONFIG_SMTP_USETLS=true,
# and must arrive over the upgraded session; a server that offers no STARTTLS,
# or whose certificate the client does not trust, must be refused when TLS is
# required.  Only the test process trusts the
# certificate (SSL_CERT_FILE for .NET's OpenSSL store, a PKCS12 trust store in
# JAVA_TOOL_OPTIONS for the JVM); lyric-mail's own trust settings are unchanged.
#
#   bash scripts/ci/smtp-roundtrip-e2e.sh [dotnet] [jvm]
# LYRIC_BIN overrides the binary (default: the AOT build for BUILD_CONFIG).
# On jvm, LYRIC_MAVEN_RESOLVER must name lyric-resolver.jar (make maven-resolver).
# Needs openssl, and keytool for jvm.
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

# A throwaway server certificate for 127.0.0.1, the host the tests connect to.
tls="$work/tls"
mkdir -p "$tls"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=127.0.0.1" \
  -addext "subjectAltName=IP:127.0.0.1,DNS:localhost" \
  -keyout "$tls/key.pem" -out "$tls/cert.pem" 2>/dev/null || { echo "FAIL: openssl could not make the test certificate"; exit 1; }
if printf '%s' "${targets[*]}" | grep -q jvm; then
  keytool -importcert -noprompt -alias lyric-ci -file "$tls/cert.pem" \
    -keystore "$tls/trust.p12" -storetype PKCS12 -storepass changeit >/dev/null 2>&1 ||
    { echo "FAIL: keytool could not make the test trust store"; exit 1; }
fi

# Runs "$@" with the test certificate trusted by the target's TLS stack.
with_test_trust() {
  local target=$1
  shift
  if [ "$target" = jvm ]; then
    JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:-} -Djavax.net.ssl.trustStore=$tls/trust.p12 -Djavax.net.ssl.trustStorePassword=changeit -Djavax.net.ssl.trustStoreType=PKCS12" "$@"
  else
    SSL_CERT_FILE="$tls/cert.pem" "$@"
  fi
}

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
  before=$(find "$out" -name "*.eml" | wc -l)
  LYRIC_CONFIG_SMTP_PASSWORD=wrong LYRIC_MAIL_TEST_ROUNDTRIP=1 \
    "$lyric_bin" test --target "$target" --manifest lyric-mail/lyric.toml >"$work/$target-badauth.log" 2>&1 && {
    echo "FAIL: --target $target accepted wrong credentials"; fail=1; }
  after=$(find "$out" -name "*.eml" | wc -l)
  if [ "$before" -ne "$after" ]; then echo "FAIL: --target $target delivered mail with wrong credentials"; fail=1; fi

  # TLS required and this server offers no STARTTLS: refused, nothing delivered.
  before=$(find "$out" -name "*.eml" | wc -l)
  LYRIC_CONFIG_SMTP_USETLS=true LYRIC_MAIL_TEST_ROUNDTRIP=1 with_test_trust "$target" \
    "$lyric_bin" test --target "$target" --manifest lyric-mail/lyric.toml >"$work/$target-notls.log" 2>&1 && {
    echo "FAIL: --target $target sent with TLS required to a server without STARTTLS"; fail=1; }
  after=$(find "$out" -name "*.eml" | wc -l)
  if [ "$before" -ne "$after" ]; then echo "FAIL: --target $target delivered mail without TLS"; fail=1; fi

  kill "$server_pid" 2>/dev/null; server_pid=""

  # The same round trip over STARTTLS.
  tout="$work/$target-tls"
  mkdir -p "$tout"
  python3 scripts/ci/smtp_capture_server.py "$tout" --user ci-user --password ci-secret \
    --tls "$tls/cert.pem" "$tls/key.pem" &
  server_pid=$!
  for _ in $(seq 1 50); do [ -s "$tout/port" ] && break; sleep 0.1; done
  if [ ! -s "$tout/port" ]; then echo "FAIL: TLS capture server did not start"; exit 1; fi
  # A certificate the client does not trust is refused, and nothing is sent.
  LYRIC_CONFIG_SMTP_PORT="$(cat "$tout/port")" LYRIC_CONFIG_SMTP_USETLS=true LYRIC_MAIL_TEST_ROUNDTRIP=1 \
    "$lyric_bin" test --target "$target" --manifest lyric-mail/lyric.toml >"$work/$target-untrusted.log" 2>&1 && {
    echo "FAIL: --target $target accepted an untrusted server certificate"; fail=1; }
  if compgen -G "$tout/*.eml" >/dev/null; then echo "FAIL: --target $target delivered mail to an untrusted server"; fail=1; fi
  echo "=== SMTP round trip over STARTTLS, --target $target (server on port $(cat "$tout/port")) ==="
  if ! LYRIC_CONFIG_SMTP_PORT="$(cat "$tout/port")" LYRIC_CONFIG_SMTP_USETLS=true LYRIC_MAIL_TEST_ROUNDTRIP=1 \
    with_test_trust "$target" "$lyric_bin" test --target "$target" --manifest lyric-mail/lyric.toml >"$work/$target-tls.log" 2>&1; then
    echo "FAIL: lyric test --target $target over STARTTLS"; tail -40 "$work/$target-tls.log"; fail=1
  fi
  if ! python3 scripts/ci/smtp_verify.py "$tout"; then
    echo "--- STARTTLS round trip for --target $target:"; tail -30 "$work/$target-tls.log"; fail=1
  fi
  for env_file in "$tout"/*.envelope; do
    [ -e "$env_file" ] || continue
    grep -qx "tls=yes" "$env_file" || { echo "FAIL: --target $target delivered $(basename "$env_file") without STARTTLS"; fail=1; }
  done

  kill "$server_pid" 2>/dev/null; server_pid=""
done

[ "$fail" -eq 0 ] && echo "lyric-mail SMTP round trip, plain and STARTTLS (${targets[*]}): ok"
exit "$fail"
