#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# native-plugin-e2e.sh — the plugin runs with a native side (docs/69): a native
# Std.Plugin host driving native and dotnet plugin processes (D207), protocol
# sessions with native hosts and plugins and a dotnet host driving a native
# plugin (docs/69 §4.3), a native host loading a trusted plugin's
# `--shape plugin` library into its own process (D231, docs/69 §10), and
# lyric-ui plugin widgets with native and dotnet hosts and native plugins
# (D272).
#
# Runs on Linux x86-64 (native-backend-self-tests.sh) and on macOS arm64 and
# Linux arm64 (.github/workflows/native-platforms.yml, #8563).  The dotnet
# sides need only the `lyric` binary and a .NET runtime: a NativeAOT-linked
# `lyric` carries the whole compiler, so it builds dotnet payloads on any host.
#
# Every run happens even when an earlier one fails; the script prints a
# summary and exits non-zero if any did.
#
# Usage: native-plugin-e2e.sh <lyric-binary>
# ---------------------------------------------------------------------------
set -uo pipefail

LYRIC_BIN="${1:?usage: native-plugin-e2e.sh <lyric-binary>}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

failed=()
run() {
  echo "=== $* ==="
  if bash "scripts/ci/$1" "$LYRIC_BIN" "${@:2}"; then :; else
    echo "::error::plugin run failed: $*"
    failed+=("$*")
  fi
}

run plugin-e2e.sh native native
run plugin-e2e.sh native dotnet
run plugin-protocol-e2e.sh native native
run plugin-protocol-e2e.sh native dotnet
run plugin-protocol-e2e.sh dotnet native
run plugin-trusted-e2e.sh native
run ui-widget-plugins-e2e.sh native native
run ui-widget-plugins-e2e.sh dotnet native

if [ "${#failed[@]}" -gt 0 ]; then
  echo "${#failed[@]} plugin run(s) failed:"
  printf '  %s\n' "${failed[@]}"
  exit 1
fi
echo "all native plugin runs passed"
