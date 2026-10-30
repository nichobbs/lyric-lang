#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# plugin-suites.sh — the plugin system's managed-target suites (docs/69, D207).
#
#   1. The custom source generator example (generators are the compiler's own
#      plugin point): scripts/ci/source-generator-e2e.sh, and the same
#      generator published, restored from a registry and from git as a signed
#      artifact with its key pinned in lyric.lock (D266):
#      scripts/ci/source-generator-restore-e2e.sh.
#   2. Std.Plugin's manifest, payload and boundary-error tests and
#      Std.PluginSign's listing and signature tests on dotnet and the JVM
#      (lyric-stdlib/tests/plugin_manifest_tests.l, plugin_sign_tests.l),
#      Std.PluginCatalogue (plugin_catalogue_tests.l), `lyric plugin
#      keygen`/`sign`/`verify` (scripts/ci/plugin-sign-e2e.sh) and `lyric plugin
#      catalogue`/`install`/`pack --zip` (scripts/ci/plugin-catalogue-e2e.sh).
#   3. The runtime against a real plugin process, every pair of a dotnet or
#      JVM host and a dotnet or JVM plugin (scripts/ci/plugin-e2e.sh).
#   4. A plugin written with the D207 annotations against the generated host
#      side, the same pairs (scripts/ci/plugin-generated-e2e.sh).
#   5. Protocol points: a supervised session with a protocol plugin and
#      requests routed through its grants, the same pairs
#      (scripts/ci/plugin-protocol-e2e.sh).
#   6. The LSP example: an editor hosting a language server as a protocol
#      plugin, with dotnet and JVM hosts (scripts/ci/plugin-lsp-e2e.sh).
#   7. Trusted mode: a dotnet and a JVM host loading a plugin of its own
#      runtime into its own process (scripts/ci/plugin-trusted-e2e.sh).
#   8. `lyric plugin sdk`, `pack` and `check` with C#, Java and TypeScript
#      plugins (scripts/ci/plugin-sdk-e2e.sh).
#   8. lyric-ui widget plugins (docs/65 §6.5, D272): the Ui.Plugins.Build tests and
#      the review example's tests on dotnet, then a screen of plugin widgets
#      against real plugin processes, every pair of a dotnet or JVM host and
#      a dotnet or JVM plugin (scripts/ci/ui-widget-plugins-e2e.sh). The JVM
#      unit runs are in scripts/ci/ui-jvm-suites.sh.
#
# Native hosts and plugins, the trusted native host included, run in
# scripts/ci/native-backend-self-tests.sh and the wasm plugin in
# scripts/ci/wasm32-wasi-rt-tests.sh, the jobs with those toolchains.
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
bash scripts/ci/source-generator-restore-e2e.sh

for target in dotnet jvm; do
  "$lyric_bin" test lyric-stdlib/tests/plugin_manifest_tests.l --target "$target"
  "$lyric_bin" test lyric-stdlib/tests/plugin_sign_tests.l --target "$target"
  "$lyric_bin" test lyric-stdlib/tests/plugin_catalogue_tests.l --target "$target"
done
bash scripts/ci/plugin-sign-e2e.sh "$lyric_bin"
bash scripts/ci/plugin-catalogue-e2e.sh "$lyric_bin"

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

for host in dotnet jvm; do
  echo "== plugin-lsp-e2e: $host host"
  bash scripts/ci/plugin-lsp-e2e.sh "$lyric_bin" "$host"
done

for target in dotnet jvm; do
  echo "== plugin-trusted-e2e: $target host, $target plugin in process"
  bash scripts/ci/plugin-trusted-e2e.sh "$lyric_bin" "$target"
done

LYRIC="$lyric_bin" bash scripts/ci/plugin-sdk-e2e.sh

# A dotnet project build links its path dependencies' DLLs from their bin/
# directories, so the libraries are built first.
for manifest in lyric-ui/plugins/lyric.toml lyric-ui/plugins/build/lyric.toml lyric-ui/lyric.toml; do
  "$lyric_bin" build --manifest "$manifest"
done
"$lyric_bin" test --manifest lyric-ui/plugins/build/lyric.toml
"$lyric_bin" test --manifest examples/plugins/ui-widgets/review/lyric.toml
for host in dotnet jvm; do
  for plugin in dotnet jvm; do
    echo "== ui-widget-plugins-e2e: $host host, $plugin plugin"
    bash scripts/ci/ui-widget-plugins-e2e.sh "$lyric_bin" "$host" "$plugin"
  done
done
