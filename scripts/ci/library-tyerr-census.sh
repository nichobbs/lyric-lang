#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# library-tyerr-census.sh - the silent-TyError census (I0001, D341, D355) over
# every library manifest.
#
# The stage 2 emit covers the compiler and the standard library; the ecosystem
# libraries are checked by the same checker and the I0001 gate rejects a silent
# site in any program, so each library manifest is built and every I0001 it
# reports is a site.  The count is zero
# (D355), so any site fails the run: a new silent site is a regression of the
# census, not a number to track.
#
# I0001 is reported only for a program that type-checks (a file that already
# has an error reports its own error, not its cascades), so a build that stops
# before the checker finishes proves nothing about its sites.  The checker has
# finished when the build succeeds or reports I0001; a build that exits non-zero
# without one (an error of any class, or a failure with no code, such as a
# malformed dependency manifest) is listed as UNCHECKED, never counted as clean,
# and fails the run (D386): a manifest the census cannot judge is a hole in it,
# so it is fixed or listed as native-only, not tolerated.  A build that fails
# loading a library dependency that is built later in the run is retried once
# the dependency exists.  The sites are printed before the unchecked builds.
#
# Libraries written for `--target native` are not built here: resolving their
# system libraries and the runtime archive precedes compilation, so a runner
# without that toolchain could never judge them.  Their native-platforms.yml e2e
# jobs build them with it, and I0001 is an error there too.
#
# Usage: library-tyerr-census.sh [path/to/lyric] [dotnet|jvm|native ...]
# ---------------------------------------------------------------------------
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LYRIC="${1:-$REPO_ROOT/bin/lyric}"
shift || true
OVERRIDE_TARGETS=("$@")

NATIVE_ONLY=(
  lyric-access/platform lyric-draw lyric-gpu lyric-gpu-window lyric-text lyric-window
  lyric-game/platform lyric-ui/native/host
)

# Builds the census cannot judge for a reason the census does not own, each with
# the tracked issue that fixes it ("manifest|target|issue").  They are reported,
# not failed; any other unchecked build fails the run (D386).  The fourth field
# is the diagnostic code the issue covers: the build is known only when that code
# is present and no other coded error and no timeout is (a new failure in the same
# build stays unchecked).  Format: "manifest|target|issue|code".
KNOWN_UNCHECKED=(
  "lyric-ui/lyric.toml|jvm|#8886|M0004"
)

export NuGetAudit=false

cd "$REPO_ROOT"

is_native_only() {
  local dir="$1" n
  for n in "${NATIVE_ONLY[@]}"; do [[ "$dir" == "$n" ]] && return 0; done
  return 1
}

jobs_list=()
skipped_native=()
for manifest in lyric-*/lyric.toml lyric-*/*/lyric.toml lyric-ui/native/*/lyric.toml; do
  [[ -f "$manifest" ]] || continue
  dir="$(dirname "$manifest")"
  [[ "$dir" == "lyric-compiler/lyric" ]] && continue
  if [[ ${#OVERRIDE_TARGETS[@]} -gt 0 ]]; then
    for t in "${OVERRIDE_TARGETS[@]}"; do jobs_list+=("$manifest|$t"); done
  elif is_native_only "$dir"; then
    skipped_native+=("$dir")
  else
    jobs_list+=("$manifest|dotnet" "$manifest|jvm")
  fi
done

sites_file="$(mktemp)"
unchecked_file="$(mktemp)"
known_file="$(mktemp)"
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
      rc=0
      timeout 900 "$LYRIC" build --manifest "$manifest" --target "$target" >"$log" 2>&1 || rc=$?
      if grep -qE "restored dep .* failed to load|local dep '.*' not built" "$log" && [[ "$round" -lt 3 ]]; then
        retry+=("$job")
        rm -f "$log"
        continue
      fi
      grep 'I0001' "$log" | sed "s|$REPO_ROOT/||" | sed "s|^|[$target] |" >>"$sites_file" || true
      # The checker completed for the whole program when the build succeeded,
      # reported I0001, or reached JVM code generation, which runs only after
      # every package type-checked.  Nothing else proves it: the JVM front end
      # rejects a `main` return type (J001) before checking, and the middle end
      # (M) stops on one package before checking the next.  A build that exits
      # non-zero otherwise is unchecked (an error of any class, or a failure
      # with no code such as a malformed dependency manifest or a timeout), not
      # clean.  Only the exact I0001 diagnostic is a site.
      if [[ "$rc" -ne 0 ]] && ! grep -qF 'error[I0001]' "$log" && ! grep -qF 'JVM codegen failed' "$log"; then
        reason="$(grep -vF 'error[I0001]' "$log" | grep -m1 -iE 'error|failed|malformed|missing|cannot|not built' | sed "s|$REPO_ROOT/||" | cut -c1-160)"
        [[ -n "$reason" ]] || reason="exit $rc: $(tail -n1 "$log" | cut -c1-140)"
        known=""
        for k in "${KNOWN_UNCHECKED[@]+"${KNOWN_UNCHECKED[@]}"}"; do
          IFS='|' read -r km kt ki kc <<<"$k"
          [[ "$km|$kt" == "$manifest|$target" && "$rc" -ne 124 ]] || continue
          grep -qF "error[$kc]" "$log" || continue
          other="$(grep -oE 'error\[[A-Z][0-9]+\]' "$log" | grep -vF "error[$kc]" || true)"
          [[ -z "$other" ]] && known="$ki"
        done
        if [[ -n "$known" ]]; then
          echo "$manifest ($target): tracked in $known: $reason" >>"$known_file"
        else
          echo "$manifest ($target): $reason" >>"$unchecked_file"
        fi
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
if [[ ${#skipped_native[@]} -gt 0 ]]; then
  echo "::notice::native-only libraries not built here (their native-platforms.yml e2e jobs build them with the real toolchain, where the always-on I0001 fails a silent site): ${skipped_native[*]}"
fi
echo "::notice::I0001 silent TyError sites across the library manifests: ${count} (${checked}/${attempted} builds checked, ${unchecked} unchecked)"
# The sites first: a run with both findings must show where the sites are.
if [[ "$count" -gt 0 ]]; then
  head -200 "$sites_file"
fi
if [[ -s "$known_file" ]]; then
  echo "Known unchecked builds (tracked, not failing):"
  cat "$known_file"
fi
if [[ "$unchecked" -gt 0 ]]; then
  echo "UNCHECKED builds (stopped before the census could see them):"
  cat "$unchecked_file"
fi
if [[ "$count" -gt 0 ]]; then
  echo "library-tyerr-census: ${count} silent TyError site(s); type each one or name it (see docs/decisions/D355)" >&2
fi
if [[ "$unchecked" -gt 0 ]]; then
  echo "library-tyerr-census: ${unchecked} build(s) stopped before the census could judge them; fix the build or list the manifest as native-only, never count it as clean (D386)" >&2
fi
if [[ "$count" -gt 0 || "$unchecked" -gt 0 ]]; then
  exit 1
fi
if [[ "$checked" -eq 0 ]]; then
  echo "library-tyerr-census: no manifest was checked, so the census proves nothing" >&2
  exit 1
fi
rm -f "$sites_file" "$unchecked_file" "$known_file"

# The typed-IR census (docs/70 §6.4, D542) runs here: this is the one job that already
# has the built `lyric`, and ci.yml has no bytes to spare for a job of its own
# (scripts/ci/check-workflow-size.sh).  Its exit status is this script's: the standard
# library gate decides it, and --wide adds the compiler, ecosystem and self-test counts
# without gating them (docs/70 §13 phase 3a).  The self-tests are left out here: each is
# a build of its own, hundreds of them; run `TIR_CENSUS_AREAS=self-tests` by hand for those.
TIR_CENSUS_AREAS="compiler ecosystem" bash "$REPO_ROOT/scripts/ci/tir-census.sh" "$LYRIC" --wide
