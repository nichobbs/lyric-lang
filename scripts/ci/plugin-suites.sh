#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# plugin-suites.sh — the plugin system's managed-target suites (docs/69, D207).
#
#   1. The custom source generator example (generators are the compiler's own
#      plugin point): scripts/ci/source-generator-e2e.sh.
#   2. Std.Plugin's manifest, payload and boundary-error tests on dotnet and
#      the JVM (lyric-stdlib/tests/plugin_manifest_tests.l).
#   3. The runtime against a real plugin process, every pair of a dotnet or
#      JVM host and a dotnet or JVM plugin (scripts/ci/plugin-e2e.sh).
#   4. A plugin written with the D207 annotations against the generated host
#      side, the same pairs (scripts/ci/plugin-generated-e2e.sh).
#   5. Protocol points: a supervised session with a protocol plugin and
#      requests routed through its grants, the same pairs
#      (scripts/ci/plugin-protocol-e2e.sh).
#   6. `lyric plugin sdk`, `pack` and `check` with C#, Java and TypeScript
#      plugins (scripts/ci/plugin-sdk-e2e.sh).
#
# Native hosts and plugins run in scripts/ci/native-backend-self-tests.sh and
# the wasm plugin in scripts/ci/wasm32-wasi-rt-tests.sh, the jobs with those
# toolchains.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

BUILD_CONFIG="${BUILD_CONFIG:-Debug}"
lyric_bin="${LYRIC_CLI_PATH:-bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric}"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin"
  exit 1
fi
case "$lyric_bin" in
  /*) ;;
  *) lyric_bin="$REPO_ROOT/$lyric_bin" ;;
esac
export LYRIC_CLI_PATH="$lyric_bin"

bash scripts/ci/source-generator-e2e.sh

for target in dotnet jvm; do
  "$lyric_bin" test lyric-stdlib/tests/plugin_manifest_tests.l --target "$target"
done

for host in dotnet jvm; do
  for plugin in dotnet jvm; do
    echo "== plugin-e2e: $host host, $plugin plugin"
    bash scripts/ci/plugin-e2e.sh "$lyric_bin" "$host" "$plugin"
    echo "== plugin-generated-e2e: $host host, $plugin plugin"
    bash scripts/ci/plugin-generated-e2e.sh "$lyric_bin" "$host" "$plugin"
    echo "== plugin-protocol-e2e: $host host, $plugin plugin"
    bash scripts/ci/plugin-protocol-e2e.sh "$lyric_bin" "$host" "$plugin"
  done
done

LYRIC="$lyric_bin" bash scripts/ci/plugin-sdk-e2e.sh
