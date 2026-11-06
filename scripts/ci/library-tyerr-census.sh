#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# library-tyerr-census.sh - the silent-TyError census (W0036, D341, D355) over
# every library manifest.
#
# The stage 2 emit covers the compiler and the standard library; the ecosystem
# libraries are checked by the same checker and the I0001 gate rejects a silent
# site in any program, so each library manifest is built with
# LYRIC_TYERR_GATE=1 and every W0036 it reports is a site.  The count is zero
# (D355), so any site fails the run: a new silent site is a regression of the
# census, not a number to track.
#
# W0036 is reported only for a program that type-checks (a file that already
# has an error reports its own error, not its cascades), so a build that stops
# on a parse, type or dependency error proves nothing about its sites.  Such a
# build is listed as UNCHECKED, never counted as clean.  A build that fails
# loading a library dependency that is built later in the run is retried once
# the dependency exists.  A build that fails after checking (a missing JVM
# jar, a link step) still counts: its W0036 lines were printed first.
#
# Libraries written for `--target native` build only there; the rest build on
# dotnet and the JVM.
#
# Usage: library-tyerr-census.sh [path/to/lyric] [dotnet|jvm|native ...]
# ---------------------------------------------------------------------------
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LYRIC="${1:-$REPO_ROOT/bin/lyric}"
shift || true
OVERRIDE_TARGETS=("$@")

NATIVE_ONLY=(
  lyric-draw lyric-gpu lyric-gpu-window lyric-text lyric-window
  lyric-game/platform lyric-ui/native/host
)

export NuGetAudit=false
export LYRIC_TYERR_GATE=1

cd "$REPO_ROOT"

is_native_only() {
  local dir="$1" n
  for n in "${NATIVE_ONLY[@]}"; do [[ "$dir" == "$n" ]] && return 0; done
  return 1
}

jobs_list=()
for manifest in lyric-*/lyric.toml lyric-*/*/lyric.toml lyric-ui/native/*/lyric.toml; do
  [[ -f "$manifest" ]] || continue
  dir="$(dirname "$manifest")"
  [[ "$dir" == "lyric-compiler/lyric" ]] && continue
  if [[ ${#OVERRIDE_TARGETS[@]} -gt 0 ]]; then
    for t in "${OVERRIDE_TARGETS[@]}"; do jobs_list+=("$manifest|$t"); done
  elif is_native_only "$dir"; then
    jobs_list+=("$manifest|native")
  else
    jobs_list+=("$manifest|dotnet" "$manifest|jvm")
  fi
done

sites_file="$(mktemp)"
unchecked_file="$(mktemp)"
checked=0
attempted=${#jobs_list[@]}
# One phase per target: a JVM build writes its jar under the same `.dll` name
# in the library's bin/ as a dotnet build, so the dotnet dependents of a
# library must all be built before any JVM build of it.
for phase in dotnet jvm native; do
  pending=()
  for job in "${jobs_list[@]}"; do
    [[ "${job##*|}" == "$phase" ]] && pending+=("$job")
  done
  for round in 1 2 3; do
    [[ ${#pending[@]} -gt 0 ]] || break
    retry=()
    for job in "${pending[@]}"; do
      manifest="${job%%|*}"
      target="${job##*|}"
      log="$(mktemp)"
      timeout 900 "$LYRIC" build --manifest "$manifest" --target "$target" >"$log" 2>&1
      if grep -q 'restored dep .* failed to load' "$log" && [[ "$round" -lt 3 ]]; then
        retry+=("$job")
        rm -f "$log"
        continue
      fi
      grep 'W0036' "$log" | sed "s|$REPO_ROOT/||" | sed "s|^|[$target] |" >>"$sites_file" || true
      if grep -qE 'restored dep .* failed to load|error\[(T|P|L)[0-9]+\]' "$log"; then
        reason="$(grep -m1 -E 'restored dep .* failed to load|error\[(T|P|L)[0-9]+\]' "$log" | sed "s|$REPO_ROOT/||" | cut -c1-160)"
        echo "$manifest ($target): $reason" >>"$unchecked_file"
      else
        checked=$((checked + 1))
      fi
      rm -f "$log"
    done
    pending=("${retry[@]+"${retry[@]}"}")
  done
done

sort -u "$sites_file" -o "$sites_file"
count=$(grep -c . "$sites_file" || true)
unchecked=$(grep -c . "$unchecked_file" || true)
echo "::notice::W0036 silent TyError sites across the library manifests: ${count} (${checked}/${attempted} builds checked, ${unchecked} unchecked)"
if [[ "$unchecked" -gt 0 ]]; then
  echo "UNCHECKED builds (stopped before the census could see them):"
  cat "$unchecked_file"
fi
if [[ "$count" -gt 0 ]]; then
  head -200 "$sites_file"
  echo "library-tyerr-census: ${count} silent TyError site(s); type each one or name it (see docs/decisions/D355)" >&2
  exit 1
fi
if [[ "$checked" -eq 0 ]]; then
  echo "library-tyerr-census: no manifest was checked, so the census proves nothing" >&2
  exit 1
fi
rm -f "$sites_file" "$unchecked_file"
