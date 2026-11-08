#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# tir-census.sh - the typed-IR census (docs/70 §6.4, §12.2, D540) over the
# standard library's test programs.
#
# Each file is built with `lyric build --verify-ir`, which numbers its nodes,
# builds every function body into Lyric.Tir and runs Lyric.Tir.Verify over the
# bodies that built.  Two numbers come out:
#
#   I0003  verifier diagnostics over built bodies.  Zero, and a regression is a
#          failure: a body the builder produced must be well formed.
#   I0002  bodies the builder cannot build yet.  Reported per run, not gated;
#          phase 3a drives it to zero, after which it becomes a gate too.
#
# A build that exits non-zero without a census line did not reach the checker's
# end; it is listed as UNCHECKED and fails the run (as the I0001 census does,
# D386), so a file the census cannot judge is a hole in it, not a pass.
#
# Usage: tir-census.sh [path/to/lyric] [file.l ...]
# ---------------------------------------------------------------------------
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LYRIC="${1:-$REPO_ROOT/bin/lyric}"
shift || true
FILES=("$@")
if [[ ${#FILES[@]} -eq 0 ]]; then
  while IFS= read -r f; do FILES+=("$f"); done < <(cd "$REPO_ROOT" && ls lyric-stdlib/tests/*.l | sort)
fi

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
i0003=0
built=0
total=0
unchecked=()
declare -A rules

cd "$REPO_ROOT"
for f in "${FILES[@]}"; do
  log="$OUT/log.txt"
  LYRIC_VERIFY_IR=1 "$LYRIC" build "$f" -o "$OUT/out.dll" >"$log" 2>&1
  rc=$?
  line="$(grep -m1 '^TIR build census' "$log" || true)"
  if [[ -z "$line" ]]; then
    if [[ $rc -ne 0 ]]; then unchecked+=("$f"); fi
    continue
  fi
  # "TIR build census [x]: B of T function bodies built"
  b="$(sed -E 's/.*: ([0-9]+) of ([0-9]+) function bodies built.*/\1/' <<<"$line")"
  t="$(sed -E 's/.*: ([0-9]+) of ([0-9]+) function bodies built.*/\2/' <<<"$line")"
  built=$((built + b))
  total=$((total + t))
  d="$(grep -m1 '^I0003 census' "$log" | sed -E 's/.*: ([0-9]+) diagnostic.*/\1/' || true)"
  d="${d:-0}"
  if [[ "$d" -gt 0 ]]; then
    echo "I0003 in $f: $d"
    grep -E '^  I0003 rule: |^    e\.g\. ' "$log" | head -8
  fi
  i0003=$((i0003 + d))
  while IFS= read -r r; do
    name="$(sed -E 's/^  I0003 rule: (.*) x [0-9]+$/\1/' <<<"$r")"
    n="$(sed -E 's/^.* x ([0-9]+)$/\1/' <<<"$r")"
    rules[$name]=$(( ${rules[$name]:-0} + n ))
  done < <(grep -E '^  I0003 rule: ' "$log" || true)
done

echo "TIR census over ${#FILES[@]} file(s): $built of $total function bodies built, $((total - built)) not yet (I0002), $i0003 I0003 diagnostic(s)"
for r in "${!rules[@]}"; do echo "  I0003 rule $r: ${rules[$r]}"; done
if [[ ${#unchecked[@]} -gt 0 ]]; then
  echo "UNCHECKED (the build stopped before the census):"
  printf '  %s\n' "${unchecked[@]}"
fi
if [[ $i0003 -gt 0 || ${#unchecked[@]} -gt 0 ]]; then exit 1; fi
