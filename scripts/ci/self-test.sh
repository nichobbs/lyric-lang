#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# self-test.sh — run one self-test through the AOT `lyric` binary in CI.
#
# Every argument is forwarded verbatim to `lyric test`, e.g.
#
#   bash scripts/ci/self-test.sh --target jvm lyric-compiler/lyric/bitwise_self_test.l
#
# An optional leading `--summary "<text>"` appends <text> as a line to
# $GITHUB_STEP_SUMMARY, but only after the test run succeeds (matching the
# inline `... && echo "..." >> "$GITHUB_STEP_SUMMARY"` idiom these steps used
# to spell out by hand):
#
#   bash scripts/ci/self-test.sh --summary "Std.Tls test ran: tls_tests.l (--target jvm)" \
#     --target jvm lyric-stdlib/tests/tls_tests.l
#
# ## Why this exists
#
# Roughly 60 CI steps repeated the same eleven-line preamble — assert the
# stage-1 bundle exists, locate the AOT binary, assert it is executable — in
# front of a single `lyric test` invocation. That duplication pushed
# `.github/workflows/ci.yml` past **GitHub's 512 KB workflow-file size limit**,
# and the failure mode is silent: Actions stops creating runs for the workflow
# entirely. No error, no queued run, no annotation — the workflow still reports
# as `active` via the API, and required checks simply never report, so PRs sit
# unmergeable with nothing to point at.
#
# Observed boundary in this repo: ci.yml at 507,536 bytes ran normally;
# at 515,219 bytes no run was created for any push or pull request.
#
# Keep large inline `run:` blocks out of ci.yml. A step that needs more than a
# few lines of shell belongs in a script here, where it is also testable
# locally and diffable without a 9,000-line file moving under it.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

BUILD_CONFIG="${BUILD_CONFIG:-Debug}"

SUMMARY=""
if [[ "${1:-}" == "--summary" ]]; then
  SUMMARY="${2:-}"
  shift 2
fi

if [[ $# -eq 0 ]]; then
  echo "::error::self-test.sh: no arguments; expected the argv for 'lyric test'" >&2
  exit 2
fi

if [ ! -d .bootstrap/stage1 ] || [ ! -f .bootstrap/stage1/Lyric.Lyric.Cli.dll ]; then
  echo "::error::stage 1 bundle missing; cannot run: lyric test $*" >&2
  exit 1
fi

lyric_bin="bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin; cannot run: lyric test $*" >&2
  exit 1
fi

if [[ -n "$SUMMARY" ]]; then
  "$lyric_bin" test "$@"
  # Default to /dev/null so --summary also works in local runs, where
  # GITHUB_STEP_SUMMARY is never set (this script runs under set -u).
  echo "$SUMMARY" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
else
  exec "$lyric_bin" test "$@"
fi
