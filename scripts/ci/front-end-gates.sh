#!/usr/bin/env bash
# front-end-gates.sh: the checker's name-resolution gates, in one CI step so
# the workflow stays under its size ceiling (check-workflow-size.sh).
#   - the compile-fail corpus (docs/70 §11), and
#   - the resolver differential census (docs/70 phase 2c, D314).
# Takes no arguments (each script has its own). Both run even when the first fails, so one run reports everything.
set -uo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
rc=0
bash "$here/reject-corpus.sh" || rc=1
bash "$here/resolve-diff.sh" || rc=1
exit "$rc"
