#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# ui-jvm-suites.sh — the UI library on JVM (#7378, D139): the erased-receiver
# JVM self-test that pins the backend fixes it needed, then the lyric-forms,
# lyric-ui and examples/ui-customers suites on --target jvm, then the
# browser end-to-end test against the JVM host.  lyric-ui's web
# host reaches Undertow only through lyric-web and lyric-ws, so the restore
# here also exercises transitive [maven] propagation (docs/38 §4).
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

BUILD_CONFIG="${BUILD_CONFIG:-Debug}"

lyric_bin="bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin; skipping the UI JVM suites"
  exit 1
fi
bash scripts/ci/self-test.sh --target jvm lyric-compiler/jvm/erased_receiver_jvm_self_test.l
# Serialized against the job's other `make maven-resolver` callers
# (see lyric-web-undertow-jvm-smoke.sh).
flock /tmp/lyric-ci-maven-resolver-build.lock -c 'make maven-resolver'
export LYRIC_MAVEN_RESOLVER="$PWD/resolver/target/lyric-resolver.jar"
"$lyric_bin" restore --manifest "$PWD/lyric-ui/lyric.toml"
"$lyric_bin" restore --manifest "$PWD/examples/ui-customers/lyric.toml"
for manifest in lyric-forms lyric-ui examples/ui-customers; do
  "$lyric_bin" test --manifest "$manifest/lyric.toml" --target jvm
done
# The example driven in headless Chromium against the JVM host (#7836).
LYRIC_CLI_PATH="$lyric_bin" bash scripts/ci/ui-browser-e2e.sh --target jvm
