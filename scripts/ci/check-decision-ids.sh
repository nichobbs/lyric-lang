#!/usr/bin/env bash
# check-decision-ids.sh - fail when two files in docs/decisions/ claim the same
# decision id (#8537, #7141).
#
# An id is the filename prefix up to and including the number: D207,
# D-progress-0886, D-N-014.  Parallel PRs pick "highest + 1" independently, so
# a merge-time check is the only reliable guard.  Ids that were already
# duplicated when the check landed are listed in decision-id-allowlist.txt with
# the number of files each may keep; the list may only shrink.
#
# DECISIONS_DIR and ALLOWLIST override the defaults (used by the self-test).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
dir="${DECISIONS_DIR:-$root/docs/decisions}"
allow="${ALLOWLIST:-$root/scripts/ci/decision-id-allowlist.txt}"

declare -A allowed=()
if [[ -f "$allow" ]]; then
  while read -r id max _; do
    [[ -z "${id:-}" || "$id" == \#* ]] && continue
    allowed["$id"]="$max"
  done < "$allow"
fi

status=0
declare -A seen=()
shopt -s nullglob
for f in "$dir"/*.md; do
  name="$(basename "$f")"
  [[ "$name" == README.md ]] && continue
  if [[ "$name" =~ ^(D-progress-[0-9]+|D-[A-Za-z]+-[0-9]+|D[0-9]+)- ]]; then
    seen["${BASH_REMATCH[1]}"]+="$name "
  else
    echo "error: $name does not start with a decision id (D<n>-, D-progress-<n>-, D-<word>-<n>-)" >&2
    status=1
  fi
done

for id in "${!seen[@]}"; do
  read -r -a files <<< "${seen[$id]}"
  count=${#files[@]}
  max=${allowed[$id]:-1}
  if (( count > max )); then
    echo "error: decision id $id is claimed by $count files (at most $max allowed):" >&2
    printf '  %s\n' "${files[@]}" >&2
    status=1
  fi
done

for id in "${!allowed[@]}"; do
  read -r -a files <<< "${seen[$id]:-}"
  if (( ${#files[@]} <= 1 )); then
    echo "error: $id is in $(basename "$allow") but no longer has duplicates; remove its line" >&2
    status=1
  fi
done

if (( status != 0 )); then
  echo "Pick the next free id: one past the highest on main and in every open PR (docs/decisions/README.md)." >&2
fi
exit "$status"
