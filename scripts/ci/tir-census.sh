#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# tir-census.sh - the typed-IR census (docs/70 §6.4, §12.2, D542) over the
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
# With --wide the census also covers the compiler (its manifest), the ecosystem
# library manifests (dotnet) and the *self_test*.l programs under lyric-compiler/,
# and reports I0002/I0003 per area and per kind with a sample site.  The wide
# census only counts: it never gates, because phase 3a has not driven those
# areas to zero yet (docs/70 §13); the standard-library gate above is unchanged.
#
# TIR_CENSUS_STATE=<dir> makes the wide census resumable: each build's log and exit code
# are kept under <dir>, and a rerun with the same <dir> reuses the ones already there, so a
# run killed part-way (the self-tests area takes hours) continues instead of restarting.
# Delete <dir> (or use a new one) after rebuilding ./bin/lyric.
#
# Usage: tir-census.sh [path/to/lyric] [--wide] [file.l ...]
# ---------------------------------------------------------------------------
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LYRIC="${1:-$REPO_ROOT/bin/lyric}"
shift || true
WIDE=0
if [[ "${1:-}" == "--wide" ]]; then WIDE=1; shift; fi
FILES=("$@")
if [[ ${#FILES[@]} -eq 0 ]]; then
  while IFS= read -r f; do FILES+=("$f"); done < <(cd "$REPO_ROOT" && ls lyric-stdlib/tests/*.l | sort)
fi

# Programs the census cannot judge because they do not pass the ordinary check as a
# dotnet program.  Each is listed with the reason; a new entry needs one.
SKIP=(
  lyric-stdlib/tests/async_echo_main.l        # names Std.TcpHost.hostCloseListener, which no longer exists
  lyric-stdlib/tests/metadata_reader_tests.l  # needs the compiler packages (PeImage), built by `lyric test`
  lyric-stdlib/tests/tls_server_jvm_tests.l   # a --target jvm test (TlsListenError.InvalidConfig, mTLS helpers)
)
filtered=()
for f in "${FILES[@]}"; do
  skip=0
  for s in "${SKIP[@]}"; do [[ "$f" == "$s" ]] && skip=1; done
  [[ $skip -eq 0 ]] && filtered+=("$f")
done
FILES=("${filtered[@]}")

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
i0003=0
built=0
total=0
judged=0
unchecked=()
declare -A rules
declare -A kinds
declare -A samples
# Per area (the wide census): bodies built, bodies total, I0003, builds judged / attempted.
declare -A a_built a_total a_i0003 a_judged a_tried
declare -A a_kinds a_samples a_unchecked

# Reads the census lines of one build log into the totals under the area name.  A
# project build prints one census per package, so every line counts, not only the first.
absorb_log() {
  local area="$1" name="$2" log="$3" rc="$4"
  local lines b t d r n site k
  lines="$(grep -c '^TIR build census' "$log" || true)"
  a_tried[$area]=$(( ${a_tried[$area]:-0} + 1 ))
  if [[ "$lines" -eq 0 ]]; then
    if [[ $rc -ne 0 ]]; then a_unchecked[$area]="${a_unchecked[$area]:-}${name}(exit $rc) "; fi
    return 0
  fi
  judged=$((judged + 1))
  a_judged[$area]=$(( ${a_judged[$area]:-0} + 1 ))
  while IFS= read -r l; do
    b="$(sed -E 's/.*: ([0-9]+) of ([0-9]+) function bodies built.*/\1/' <<<"$l")"
    t="$(sed -E 's/.*: ([0-9]+) of ([0-9]+) function bodies built.*/\2/' <<<"$l")"
    built=$((built + b)); total=$((total + t))
    a_built[$area]=$(( ${a_built[$area]:-0} + b )); a_total[$area]=$(( ${a_total[$area]:-0} + t ))
  done < <(grep '^TIR build census' "$log")
  d=0
  while IFS= read -r l; do
    n="$(sed -E 's/.*: ([0-9]+) diagnostic.*/\1/' <<<"$l")"
    d=$((d + n))
  done < <(grep '^I0003 census' "$log" || true)
  if [[ "$d" -gt 0 ]]; then
    echo "I0003 in $name: $d"
    grep -E '^  I0003 rule: |^    e\.g\. ' "$log" | head -8
  fi
  i0003=$((i0003 + d))
  a_i0003[$area]=$(( ${a_i0003[$area]:-0} + d ))
  while IFS= read -r r; do
    k="$(sed -E 's/^  I0003 rule: (.*) x [0-9]+$/\1/' <<<"$r")"
    n="$(sed -E 's/^.* x ([0-9]+)$/\1/' <<<"$r")"
    rules[$k]=$(( ${rules[$k]:-0} + n ))
  done < <(grep -E '^  I0003 rule: ' "$log" || true)
  while IFS= read -r r; do
    site="$(sed -nE 's/^.* x [0-9]+ \(first at ([0-9:]+)\)$/\1/p' <<<"$r")"
    r="$(sed -E 's/ \(first at [0-9:]+\)$//' <<<"$r")"
    k="$(sed -E 's/^  no builder case: (.*) x [0-9]+$/\1/' <<<"$r")"
    n="$(sed -E 's/^.* x ([0-9]+)$/\1/' <<<"$r")"
    kinds[$k]=$(( ${kinds[$k]:-0} + n ))
    a_kinds["$area|$k"]=$(( ${a_kinds["$area|$k"]:-0} + n ))
    if [[ -n "$site" && -z "${samples[$k]:-}" ]]; then samples[$k]="$name:$site"; fi
    if [[ -n "$site" && -z "${a_samples["$area|$k"]:-}" ]]; then a_samples["$area|$k"]="$name:$site"; fi
  done < <(grep -E '^  no builder case: ' "$log" || true)
}

# Runs one wide-census build into $log, or reuses the kept result (see TIR_CENSUS_STATE).
# Sets rc.  Usage: run_cached <key> <timeout> <command...>
run_cached() {
  local key="$1" tmo="$2"; shift 2
  local keep=""
  if [[ -n "${TIR_CENSUS_STATE:-}" ]]; then
    mkdir -p "$TIR_CENSUS_STATE"
    keep="$TIR_CENSUS_STATE/$(tr '/ ' '__' <<<"$key")"
    if [[ -f "$keep.rc" ]]; then cp "$keep.log" "$log"; rc="$(cat "$keep.rc")"; return 0; fi
  fi
  rc=0
  timeout "$tmo" "$@" >"$log" 2>&1 || rc=$?
  if [[ -n "$keep" ]]; then cp "$log" "$keep.log"; echo "$rc" >"$keep.rc"; fi
}

cd "$REPO_ROOT"
for f in "${FILES[@]}"; do
  log="$OUT/log.txt"
  "$LYRIC" build --verify-ir "$f" -o "$OUT/out.dll" >"$log" 2>&1
  rc=$?
  if ! grep -q '^TIR build census' "$log" && [[ $rc -ne 0 ]]; then unchecked+=("$f"); fi
  absorb_log stdlib-tests "$f" "$log" "$rc"
done

echo "TIR census over ${#FILES[@]} file(s): $built of $total function bodies built, $((total - built)) not yet (I0002), $i0003 I0003 diagnostic(s)"
for r in "${!rules[@]}"; do echo "  I0003 rule $r: ${rules[$r]}"; done
# Sorted by the count that follows the first colon; the "(e.g. file:L:C)" suffix adds
# colons but the numeric key reads only the leading count.
for k in "${!kinds[@]}"; do echo "  I0002 kind ${k}: ${kinds[$k]}${samples[$k]:+ (e.g. ${samples[$k]})}"; done | sort -t: -k2 -n -r | head -25
if [[ ${#unchecked[@]} -gt 0 ]]; then
  echo "UNCHECKED (the build stopped before the census):"
  printf '  %s\n' "${unchecked[@]}"
fi
# A build that exits 0 without a census line is not judged; if the line's format ever
# changed, every program would be skipped and the job would still pass, so a census that
# judged fewer than half of its programs fails.
if [[ $((judged * 2)) -lt ${#FILES[@]} || $judged -eq 0 ]]; then
  echo "TIR census judged only $judged of ${#FILES[@]} program(s): the census line is missing from the build output" >&2
  exit 1
fi
gate_rc=0
if [[ $i0003 -gt 0 || ${#unchecked[@]} -gt 0 ]]; then gate_rc=1; fi
# A call that leaves out an argument another package's function or record declares (D482).
bash "$REPO_ROOT/scripts/ci/tir-foreign-defaults-e2e.sh" "$LYRIC" || gate_rc=1

if [[ $WIDE -eq 0 ]]; then exit $gate_rc; fi

# ---------------------------------------------------------------------------
# The wide census (counts only): compiler, ecosystem libraries, self-tests.
# ---------------------------------------------------------------------------
export NuGetAudit=false
NATIVE_ONLY=(
  lyric-access/platform lyric-draw lyric-gpu lyric-gpu-window lyric-text lyric-window
  lyric-game/platform lyric-ui/native/host
)
is_native_only() {
  local dir="$1" n
  for n in "${NATIVE_ONLY[@]}"; do [[ "$dir" == "$n" ]] && return 0; done
  return 1
}

# TIR_CENSUS_AREAS picks the wide areas (default all three); TIR_CENSUS_LINKED=1 also
# judges the self-tests that import compiler packages, by running them under `lyric test`
# (about 25 s each, so CI leaves it off and such a test is counted as unchecked).
log="$OUT/wide.txt"
AREAS=" ${TIR_CENSUS_AREAS:-compiler ecosystem self-tests} "

# The compiler: the per-package emit stage 1 uses (bootstrap.sh stage1_cli_bundle) over a
# driver that imports Lyric.Cli, so every package of the self-hosted compiler and its
# standard-library import closure is checked.  The compiler has no buildable manifest
# (its packages are emitted one by one), so a plain --manifest build cannot judge it.
if [[ "$AREAS" == *" compiler "* ]]; then
mkdir -p "$OUT/compiler-driver" "$OUT/compiler-out"
cat > "$OUT/compiler-driver/driver.l" <<'DRIVER'
package Lyric.CliBundle
import Lyric.Cli
import Std.Time
import Std.Math
import Std.Testing.Mocking
func main(): Unit { }
DRIVER
rc=0
LYRIC_VERIFY_IR=1 timeout 3000 "$LYRIC" --internal-perpackage-build "$OUT/compiler-driver/driver.l" "$OUT/compiler-out" --target dotnet >"$log" 2>&1 || rc=$?
sed -i "s|$REPO_ROOT/||g" "$log"
absorb_log compiler "Lyric.Cli closure" "$log" "$rc"
fi

if [[ "$AREAS" == *" ecosystem "* ]]; then
# The ecosystem libraries, dotnet only (the JVM build reports the same checker census).
for manifest in lyric-*/lyric.toml lyric-*/*/lyric.toml lyric-ui/native/*/lyric.toml; do
  [[ -f "$manifest" ]] || continue
  dir="$(dirname "$manifest")"
  [[ "$dir" == "lyric-compiler/lyric" || "$dir" == lyric-compiler/* ]] && continue
  is_native_only "$dir" && continue
  run_cached "eco-$manifest" 900 "$LYRIC" build --verify-ir --manifest "$manifest" --target dotnet
  absorb_log ecosystem "$manifest" "$log" "$rc"
done
fi

if [[ "$AREAS" == *" self-tests "* ]]; then
# The compiler's self-tests, one program each.
while IFS= read -r f; do
  run_cached "st-$f" 600 "$LYRIC" build --verify-ir "$f" -o "$OUT/st.dll"
  if ! grep -q '^TIR build census' "$log" && [[ "${TIR_CENSUS_LINKED:-0}" == 1 ]]; then
    # A program that imports compiler packages builds only through `lyric test`, which
    # links them as restored dependencies; the census line is the same.  The tests run too.
    run_cached "stl-$f" 600 env LYRIC_VERIFY_IR=1 "$LYRIC" test --target dotnet "$f"
  fi
  absorb_log self-tests "$f" "$log" "$rc"
done < <(find lyric-compiler -name '*self_test*.l' -not -path '*/testdata/*' | sort)
fi

echo
echo "Wide TIR census (counts only, not gated):"
for area in stdlib-tests compiler ecosystem self-tests; do
  tried="${a_tried[$area]:-0}"
  [[ "$tried" -eq 0 ]] && continue
  echo "  [$area] ${a_built[$area]:-0} of ${a_total[$area]:-0} bodies built, $(( ${a_total[$area]:-0} - ${a_built[$area]:-0} )) not yet (I0002), ${a_i0003[$area]:-0} I0003; ${a_judged[$area]:-0} of $tried build(s) judged"
  for k in "${!a_kinds[@]}"; do
    [[ "${k%%|*}" == "$area" ]] || continue
    echo "    I0002 kind ${k#*|}: ${a_kinds[$k]}${a_samples[$k]:+ (e.g. ${a_samples[$k]})}"
  done | sort -t: -k2 -n -r | head -15
  if [[ -n "${a_unchecked[$area]:-}" ]]; then
    echo "    unchecked builds: $(wc -w <<<"${a_unchecked[$area]}")"
    # shellcheck disable=SC2086
    printf '      %s\n' ${a_unchecked[$area]} | head -10
  fi
done
exit $gate_rc
