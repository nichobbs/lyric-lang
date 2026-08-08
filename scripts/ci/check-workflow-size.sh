#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# check-workflow-size.sh — fail loudly if ci.yml is approaching GitHub's
# undocumented, silent workflow-file size ceiling.
#
# See scripts/ci/self-test.sh's header for the full story: GitHub silently
# stops creating runs for a workflow file once it crosses some size boundary
# somewhere between 507,536 and 515,219 bytes (observed in this repo, #6387).
# There is no error, no queued run, no annotation — the workflow still
# reports `active` via the API, required checks simply never report, and
# every PR sits unmergeable with nothing to point at.
#
# This check runs in the (cheap) actionlint job on every push/PR so the
# failure mode is a red check here, well before the real boundary, instead
# of the workflow going silent on some unrelated PR later.  500,000 bytes
# leaves ~15 KB of headroom to react.  If this fires, extract the largest
# remaining inline `run:` blocks into scripts/ci/*.sh (self-test.sh already
# covers the common "run one self-test through the AOT binary" shape).
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKFLOW="${1:-$REPO_ROOT/.github/workflows/ci.yml}"

SOFT_CEILING=500000

size="$(stat -c%s "$WORKFLOW" 2>/dev/null || stat -f%z "$WORKFLOW")"

if [ "$size" -gt "$SOFT_CEILING" ]; then
  echo "::error::$WORKFLOW is $size bytes, over the $SOFT_CEILING-byte soft ceiling. GitHub silently stops creating runs for a workflow file past an undocumented size boundary observed in this repo between 507,536 and 515,219 bytes (#6387) -- no error, no queued run, no annotation, required checks just never report. Extract inline run: blocks into scripts/ci/*.sh (see scripts/ci/self-test.sh's header) before this lands." >&2
  exit 1
fi

echo "$WORKFLOW: $size bytes (soft ceiling $SOFT_CEILING)"
