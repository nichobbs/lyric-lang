#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# coverage-smoke-test.sh — prove `lyric test --target jvm --coverage`
# actually produces a real, non-empty Cobertura XML report.
#
# This exists so the JaCoCo coverage path (docs/03-decision-log.md) never
# rots into a silent no-op the way the old F#-era `coverage` CI job did
# (issue #5294): that job kept `dotnet-coverage collect` failing against
# five deleted F# test projects, swallowed the failure, and reported green
# while collecting zero coverage data. A CI step that merely runs
# `lyric test --coverage` and checks its own exit code would repeat that
# mistake — the flag could silently degrade to "no report written" and the
# step would still pass. Instead this script inspects the report file
# itself: it must exist, be non-empty, parse as the expected Cobertura root
# element, and report a non-trivial (`lines-valid > 0`) denominator.
#
# Usage:
#   bash scripts/ci/coverage-smoke-test.sh <jvm-test-file.l>
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

BUILD_CONFIG="${BUILD_CONFIG:-Debug}"

if [[ $# -ne 1 ]]; then
  echo "::error::coverage-smoke-test.sh: expected exactly one argument (the .l test file)" >&2
  exit 2
fi
test_file="$1"

if [ ! -d .bootstrap/stage1 ] || [ ! -f .bootstrap/stage1/Lyric.Lyric.Cli.dll ]; then
  echo "::error::stage 1 bundle missing; cannot run: lyric test $test_file --coverage" >&2
  exit 1
fi

lyric_bin="bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin; cannot run: lyric test $test_file --coverage" >&2
  exit 1
fi

# Stage JaCoCo (idempotent — make jacoco no-ops if already downloaded) and
# pin the exact jars via env vars rather than relying on search-path
# discovery, matching how CI pins LYRIC_MAVEN_RESOLVER for the bundled
# Maven resolver jar. Bounded by `timeout` as defense in depth beyond the
# curl-level --max-time: a network stall here must fail loud within
# minutes, not silently hang the whole CI job for hours (the actual
# failure mode observed on PR #6627 before curl's own timeout was added).
timeout 240 make -C "$REPO_ROOT" jacoco
export LYRIC_JACOCO_AGENT="$REPO_ROOT/.tools/jacoco/lib/jacocoagent.jar"
export LYRIC_JACOCO_CLI="$REPO_ROOT/.tools/jacoco/lib/jacococli.jar"
if [ ! -f "$LYRIC_JACOCO_AGENT" ] || [ ! -f "$LYRIC_JACOCO_CLI" ]; then
  echo "::error::make jacoco did not stage jacocoagent.jar/jacococli.jar" >&2
  exit 1
fi

"$lyric_bin" test "$test_file" --target jvm --coverage

test_dir="$(dirname "$test_file")"
base="$(basename "$test_file")"
stem="${base%.l}"
cobertura_xml="$test_dir/.lyric-test/coverage/${stem}-cobertura.xml"
jacoco_xml="$test_dir/.lyric-test/coverage/${stem}-jacoco.xml"

if [ ! -f "$jacoco_xml" ]; then
  echo "::error::coverage-smoke-test.sh: JaCoCo XML report not found at $jacoco_xml" >&2
  exit 1
fi
if [ ! -s "$jacoco_xml" ]; then
  echo "::error::coverage-smoke-test.sh: JaCoCo XML report at $jacoco_xml is empty" >&2
  exit 1
fi

if [ ! -f "$cobertura_xml" ]; then
  echo "::error::coverage-smoke-test.sh: Cobertura XML report not found at $cobertura_xml" >&2
  exit 1
fi
if [ ! -s "$cobertura_xml" ]; then
  echo "::error::coverage-smoke-test.sh: Cobertura XML report at $cobertura_xml is empty" >&2
  exit 1
fi
if ! grep -q '<coverage ' "$cobertura_xml"; then
  echo "::error::coverage-smoke-test.sh: $cobertura_xml has no <coverage> root element" >&2
  exit 1
fi

lines_valid="$(grep -o 'lines-valid="[0-9]*"' "$cobertura_xml" | head -1 | grep -o '[0-9]*')"
if [ -z "$lines_valid" ] || [ "$lines_valid" -eq 0 ]; then
  echo "::error::coverage-smoke-test.sh: $cobertura_xml reports lines-valid=0 — no real coverage data" >&2
  exit 1
fi

echo "coverage-smoke-test.sh: OK — $cobertura_xml ($lines_valid lines instrumented)"
summary="Coverage smoke test: $test_file -> $cobertura_xml ($lines_valid lines instrumented)"
echo "$summary" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
