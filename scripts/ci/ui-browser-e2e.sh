#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# ui-browser-e2e.sh — browser end-to-end test for lyric-ui's server-driven
# web host (docs/65 §10.1, #7836).  Starts examples/ui-customers on the
# requested target and drives it in headless Chromium with Playwright
# (lyric-ui/runtime/e2e/customers.e2e.mjs): render, a field error, a save,
# and a dropped connection that resumes the same session.
#
# Usage: scripts/ci/ui-browser-e2e.sh [--target dotnet|jvm]
# The CLI is $LYRIC_CLI_PATH, or the AOT build for $BUILD_CONFIG.  A JVM run
# needs $LYRIC_MAVEN_RESOLVER (see ui-jvm-suites.sh).
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

target="dotnet"
while [ $# -gt 0 ]; do
  case "$1" in
    --target) target="$2"; shift 2 ;;
    *) echo "ui-browser-e2e: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
case "$target" in
  dotnet|jvm) ;;
  *) echo "ui-browser-e2e: --target must be dotnet or jvm, got '$target'" >&2; exit 2 ;;
esac

BUILD_CONFIG="${BUILD_CONFIG:-Debug}"
lyric_bin="${LYRIC_CLI_PATH:-bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric}"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::lyric CLI not found at $lyric_bin" >&2
  exit 1
fi

PLAYWRIGHT_VERSION="1.56.1"
(
  cd lyric-ui/runtime
  if ! node --input-type=module -e "await import('playwright')" 2>/dev/null; then
    npm install --no-save --no-package-lock "playwright@${PLAYWRIGHT_VERSION}"
  fi
  # Images that ship Chromium set PLAYWRIGHT_BROWSERS_PATH; elsewhere fetch it.
  if [ -z "${PLAYWRIGHT_BROWSERS_PATH:-}" ]; then
    npx playwright install --with-deps chromium
  fi
)

port=8080
ws_port=8081
for p in "$port" "$ws_port"; do
  if (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then
    echo "::error::port $p is already in use; the example host needs it" >&2
    exit 1
  fi
done

manifest="examples/ui-customers/lyric.toml"
"$lyric_bin" build --manifest "$manifest" --target "$target"

log="$(mktemp)"
setsid "$lyric_bin" run --manifest "$manifest" --target "$target" > "$log" 2>&1 &
host_pid=$!
cleanup() {
  kill -- "-$host_pid" 2>/dev/null || true
  wait "$host_pid" 2>/dev/null || true
  rm -f "$log"
}
trap cleanup EXIT

url="http://127.0.0.1:${port}/customers/1"
ready=0
for _ in $(seq 1 240); do
  if ! kill -0 "$host_pid" 2>/dev/null; then
    echo "::error::the example host exited before serving" >&2
    cat "$log" >&2
    exit 1
  fi
  if curl -sf -o /dev/null "$url"; then
    ready=1
    break
  fi
  sleep 0.5
done
if [ "$ready" -ne 1 ]; then
  echo "::error::the example host did not serve $url within 120 s" >&2
  cat "$log" >&2
  exit 1
fi

status=0
LYRIC_UI_E2E_URL="$url" LYRIC_UI_E2E_TARGET="$target" \
  node --test lyric-ui/runtime/e2e/customers.e2e.mjs || status=$?
if [ "$status" -ne 0 ]; then
  echo "--- example host output ---" >&2
  cat "$log" >&2
fi
exit "$status"
