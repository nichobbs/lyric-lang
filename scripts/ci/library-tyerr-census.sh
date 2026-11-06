#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# library-tyerr-census.sh - the silent-TyError census (W0036, D341, D355) over
# every library manifest, on both targets.
#
# The stage 2 emit covers the compiler and the standard library; the ecosystem
# libraries are checked by the same checker and the I0001 gate rejects a silent
# site in any program, so each `lyric-*/lyric.toml` is built with
# LYRIC_TYERR_GATE=1 and every W0036 it reports is a site.  The count is zero
# (D355), so any site fails the run: a new silent site is a regression of the
# census, not a number to track.
#
# A build that fails for another reason (a missing restored dependency, an
# unrelated diagnostic) does not count here; only W0036 does.  The run fails if
# no manifest built at all, so a broken binary cannot pass as an empty census.
#
# Usage: library-tyerr-census.sh [path/to/lyric] [dotnet|jvm ...]
# ---------------------------------------------------------------------------
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LYRIC="${1:-$REPO_ROOT/bin/lyric}"
shift || true
TARGETS=("$@")
[[ ${#TARGETS[@]} -gt 0 ]] || TARGETS=(dotnet jvm)

export NuGetAudit=false
export LYRIC_TYERR_GATE=1

cd "$REPO_ROOT"
sites_file="$(mktemp)"
built=0
attempted=0

for manifest in lyric-*/lyric.toml lyric-ui/*/lyric.toml; do
  [[ -f "$manifest" ]] || continue
  for target in "${TARGETS[@]}"; do
    attempted=$((attempted + 1))
    log="$(mktemp)"
    if timeout 900 "$LYRIC" build --manifest "$manifest" --target "$target" >"$log" 2>&1; then
      built=$((built + 1))
    fi
    grep 'W0036' "$log" | sed "s|$REPO_ROOT/||" | sed "s|^|[$target] |" >>"$sites_file" || true
    rm -f "$log"
  done
done

sort -u "$sites_file" -o "$sites_file"
count=$(grep -c . "$sites_file" || true)
echo "::notice::W0036 silent TyError sites across the library manifests: ${count} (${built}/${attempted} builds succeeded)"
if [[ "$count" -gt 0 ]]; then
  head -200 "$sites_file"
  echo "library-tyerr-census: ${count} silent TyError site(s); type each one or name it (see docs/decisions/D355)" >&2
  exit 1
fi
if [[ "$built" -eq 0 ]]; then
  echo "library-tyerr-census: no manifest built, so the census proves nothing" >&2
  exit 1
fi
rm -f "$sites_file"
