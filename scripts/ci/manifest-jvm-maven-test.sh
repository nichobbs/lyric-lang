#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# manifest-jvm-maven-test.sh — run one manifest's `lyric test` on a JVM
# target that needs Maven-restored dependencies resolved first.
#
#   bash scripts/ci/manifest-jvm-maven-test.sh lyric-lambda/lyric.toml \
#     --target jvm --no-default-features --features jvm
#
# Unlike `self-test.sh` (a bare `lyric test`), this ensures `mvn` is on
# PATH, builds `resolver/target/lyric-resolver.jar` (`make maven-resolver`),
# exports `LYRIC_MAVEN_RESOLVER`, and runs `lyric restore --manifest
# <manifest>` before the test — the same sequence `lyric-web`'s Undertow
# smoke test and the `lyric-aws-secrets` JVM suite already inline, extracted
# here so a manifest whose JVM build pulls in a Maven-backed dependency
# (like `lyric-lambda`'s unconditional `import Web`, #7337) can wire a CI
# step in the same one-line `self-test.sh` form other JVM ecosystem suites
# use. `flock` on the shared per-job lock files matches the other Maven call
# sites so concurrent `background: true` steps in the same job don't race
# `apt-get install maven` or `mvn package` against each other (#7108).
#
# First argument is the manifest path; the rest is forwarded verbatim to
# `lyric test`.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

if [[ $# -lt 1 ]]; then
  echo "::error::manifest-jvm-maven-test.sh: no manifest path given" >&2
  exit 2
fi
manifest="$1"
shift

if ! command -v mvn >/dev/null 2>&1; then
  sudo rm -f /etc/apt/sources.list.d/google-chrome.list* || true
  flock /tmp/lyric-ci-apt-maven.lock -c 'sudo apt-get update -qq && sudo apt-get install -y --no-install-recommends maven'
fi
flock /tmp/lyric-ci-maven-resolver-build.lock -c 'make maven-resolver'
export LYRIC_MAVEN_RESOLVER="$PWD/resolver/target/lyric-resolver.jar"

BUILD_CONFIG="${BUILD_CONFIG:-Debug}"
lyric_bin="bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin; cannot run: lyric test --manifest $manifest $*" >&2
  exit 1
fi

"$lyric_bin" restore --manifest "$manifest"
exec "$lyric_bin" test --manifest "$manifest" "$@"
