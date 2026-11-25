#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# ui-jvm-suites.sh — the UI library on JVM (#7378, D139): the erased-receiver
# JVM self-test that pins the backend fixes it needed, then the lyric-forms,
# lyric-ui, the native host core (lyric-ui/native), Ui.Plugins.Build (lyric-ui/plugins/build), Access.Plan (lyric-access), examples/ui-customers and the
# plugin-widget review example (D272) suites on --target jvm, then the
# browser end-to-end test and the desktop-window end-to-end test against the
# JVM host.  lyric-ui's web
# host is served by lyric-web and lyric-ws over the shared Std.HttpServer
# driver, so no Maven restore is needed (docs/73 S7b, D796).
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

BUILD_CONFIG="${BUILD_CONFIG:-Debug}"

lyric_bin="bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/lyric"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin; skipping the UI JVM suites"
  exit 1
fi
bash scripts/ci/self-test.sh --target jvm lyric-compiler/jvm/erased_receiver_jvm_self_test.l
for manifest in lyric-forms lyric-ui lyric-ui/native lyric-ui/plugins/build lyric-access examples/ui-customers examples/plugins/ui-widgets/review; do
  "$lyric_bin" test --manifest "$manifest/lyric.toml" --target jvm
done
# The example driven in headless Chromium against the JVM host (#7836).
LYRIC_CLI_PATH="$lyric_bin" bash scripts/ci/ui-browser-e2e.sh --target jvm
# The desktop host in a real window under Xvfb (docs/65 U5).
LYRIC_CLI_PATH="$lyric_bin" bash scripts/ci/ui-desktop-e2e.sh --target jvm
