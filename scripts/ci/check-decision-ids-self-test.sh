#!/usr/bin/env bash
# Self-test for check-decision-ids.sh: runs it against disposable directories.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
check="$here/check-decision-ids.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail=0

run() { # name expected-exit allow-contents files...
  local name="$1" want="$2" allow="$3"; shift 3
  rm -rf "$tmp/d"; mkdir "$tmp/d"
  for f in "$@"; do : > "$tmp/d/$f"; done
  printf '%s' "$allow" > "$tmp/allow"
  local got=0
  DECISIONS_DIR="$tmp/d" ALLOWLIST="$tmp/allow" bash "$check" >/dev/null 2>&1 || got=$?
  if (( (got == 0) != (want == 0) )); then
    echo "FAIL: $name (exit $got, wanted $want)"; fail=1
  fi
}

run "unique ids pass" 0 "" README.md D1-a.md D2-b.md D-progress-0001-x.md D-N-014-y.md
run "duplicate fails" 1 "" D1-a.md D1-b.md
run "duplicate progress id fails" 1 "" D-progress-0886-a.md D-progress-0886-b.md
run "D1 and D10 are distinct" 0 "" D1-a.md D10-b.md
run "allow-listed duplicate passes" 0 $'# c\nD1 2\n' D1-a.md D1-b.md
run "allow-listed id may not grow" 1 $'D1 2\n' D1-a.md D1-b.md D1-c.md
run "stale allow-list entry fails" 1 $'D1 2\n' D1-a.md
run "file without an id fails" 1 "" notes.md
(( fail == 0 )) && echo "check-decision-ids self-test: ok"
exit "$fail"
