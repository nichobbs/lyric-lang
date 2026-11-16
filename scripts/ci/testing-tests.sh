#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# testing-tests.sh: the `testing` entry of ci.yml's ecosystem-tests matrix
# (ci.yml is at its size ceiling, scripts/ci/check-workflow-size.sh).
#
# lyric-conformance runs each interface's conformance suite against its
# in-tree backend; lyric-testing runs the mocks' own tests and the same suites
# against the mocks (docs/decisions/D604). Both manifests build their
# workspace dependencies themselves. Both run on dotnet and the JVM (D609);
# the JVM run restores the Maven dependencies of lyric-db and lyric-mail
# first and needs Java 21+ on PATH.
# Usage: LYRIC_CLI_PATH=<lyric> bash scripts/ci/testing-tests.sh
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
: "${LYRIC_CLI_PATH:?LYRIC_CLI_PATH must name the lyric binary}"

"$LYRIC_CLI_PATH" test --manifest lyric-conformance/lyric.toml
"$LYRIC_CLI_PATH" test --manifest lyric-testing/lyric.toml

bash scripts/ci/manifest-jvm-maven-test.sh lyric-conformance/lyric.toml --target jvm
bash scripts/ci/manifest-jvm-maven-test.sh lyric-testing/lyric.toml --target jvm
