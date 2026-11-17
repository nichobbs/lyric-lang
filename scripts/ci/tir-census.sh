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
# A program whose path or name says jvm (lyric-compiler/jvm/, *_jvm_self_test.l, *_jvm_tests.l) is
# built with --target jvm (D466); the JVM build prints the same census lines.
#
# With --wide the census also covers the compiler (its manifest), the ecosystem
# library manifests (dotnet) and the *self_test*.l programs under lyric-compiler/,
# and reports I0002/I0003 per area and per kind with a sample site.  The wide
# census only counts: it never gates, because phase 3a has not driven those
# areas to zero yet (docs/70 §13); the standard-library gate above is unchanged.
#
# Bodies are counted once.  A package that several programs share (the standard library's
# JVM kernels are source-loaded into each program, the compiler's packages into each
# self-test) has the same function bodies in every one of those builds, so a per-build sum
# counts one body once per program.  With LYRIC_TIR_CENSUS_BODIES=1 the checker prints one
# `TIR body` line per body (built or not, with its DefPath key and, for a body it could not
# build, each uncovered kind with its count and first site); this script keys a body of
# `Std.*`, `Lyric.*`, `Msil.*` or `Jvm.*` by that path alone and any other body by its
# program as well, and reports the unique bodies beside the raw per-build totals.  A body
# seen built in one program and not in another counts as not built.
#
# A `func main` self-test that imports compiler packages cannot be built by `lyric build`; the
# self-tests area runs it as scripts/run-numbered-self-tests.sh does (`LYRIC_LOAD_COMPILER=1 lyric
# run`) and reads the census lines of that run (D523), so no self-test is left unjudged for want of
# a path.
#
# TIR_CENSUS_STATE=<dir> makes the wide census resumable: each build's log and exit code
# are kept under <dir>, and a rerun with the same <dir> reuses the ones already there, so a
# run killed part-way (the self-tests area takes hours) continues instead of restarting.
# Delete <dir> (or use a new one) after rebuilding ./bin/lyric.
#
# TIR_CENSUS_PARTIAL=1 (with TIR_CENSUS_STATE and --wide) builds nothing: it aggregates only the
# builds already kept under the state directory, skips the standard-library phase and the e2e
# shape scripts, reports how many wide builds had no kept result, and never gates.  It lets the
# table be posted from a run that is still going or was stopped at a time limit.
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

# The target a program is built for (D466): a JVM-targeted program (its path or name says jvm)
# names JDK externs the dotnet resolver cannot see, so it is built with --target jvm, whose
# checker reports the same census.  The two tests of the native-only bounded Std.TcpHost
# operations (D605) are built with --target native: the checker prints its census before
# code generation, so the build is judged whether or not the link step has a toolchain.
# The two JVM-bridge tests that drive `Jvm.Bridge` in process are .NET programs that import
# compiler packages (CI runs them without --target), so they are built for dotnet.
# Everything else is built for dotnet.
target_of() {
  case "$1" in
    lyric-stdlib/tests/http_timeout_native_tests.l|lyric-stdlib/tests/tcp_host_bounded_native_tests.l) echo native ;;
    lyric-compiler/jvm/cross_package_generics_jvm_self_test.l|lyric-compiler/lyric/field_access_list_of_slice_add_jvm_self_test.l) echo dotnet ;;
    lyric-compiler/jvm/*|*_jvm_self_test*.l|*_jvm_tests.l|*jvm_self_test*.l) echo jvm ;;
    *) echo dotnet ;;
  esac
}

export LYRIC_TIR_CENSUS_BODIES=1
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

# Appends the body identities of one build log to the area's file (see the header): one
# tab-separated line per body (`built` or `unbuilt`, key) and per uncovered kind of an
# unbuilt body (`kind`, key, count, line:column, kind).  A body of a package every program
# shares is keyed by its path alone; any other body also by the program that declares it.
collect_bodies() {
  local area="$1" prog="$2" log="$3"
  awk -F'\t' -v prog="$prog" '
    $1 == "TIR body" {
      key = $3
      pk = key; sub(/::.*/, "", pk)
      if (substr(key, 1, 1) == "~" || pk !~ /^(Std|Lyric|Msil|Jvm)([.]|$)/) key = prog "::" key
      if ($2 == "kind") print $2 "\t" key "\t" $4 "\t" $5 "\t" $6
      else print $2 "\t" key
    }' "$log" >>"$OUT/bodies.$area"
}

# The unique-body totals of one area: `<unique> <built>` on the first line, then one line
# per uncovered kind, `<count> <kind>\t<first site>`.  A body counted twice with different
# outcomes is not built; a kind of one body counts once however many programs repeat it.
unique_bodies() {
  local f="$OUT/bodies.$1"
  [[ -s "$f" ]] || return 0
  awk -F'\t' '
    $1 == "built" { b[$2] = 1 }
    $1 == "unbuilt" { u[$2] = 1 }
    $1 == "kind" {
      id = $2 SUBSEP $5
      if (!(id in seen)) {
        seen[id] = 1; n[$5] += $3
        if (!($5 in site)) site[$5] = $2 " " $4
      }
    }
    END {
      nu = 0; nb = 0
      for (x in u) nu++
      for (x in b) if (!(x in u)) nb++
      print nb + nu, nb
      for (c in n) print n[c] " " c "\t" site[c]
    }' "$f"
}

# Reads the census lines of one build log into the totals under the area name.  A
# project build prints one census per package, so every line counts, not only the first.
absorb_log() {
  local area="$1" name="$2" log="$3" rc="$4"
  local lines b t d r n site k
  lines="$(grep -c '^TIR build census' "$log" || true)"
  a_tried[$area]=$(( ${a_tried[$area]:-0} + 1 ))
  if [[ "$lines" -eq 0 ]]; then
    if [[ $rc -ne 0 ]]; then a_unchecked[$area]="${a_unchecked[$area]:-}${name}(exit=$rc) "; fi
    return 0
  fi
  collect_bodies "$area" "$name" "$log"
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

partial_missing=0
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
  if [[ "${TIR_CENSUS_PARTIAL:-0}" == 1 ]]; then : >"$log"; rc=255; partial_missing=$((partial_missing + 1)); return 0; fi
  rc=0
  timeout "$tmo" "$@" >"$log" 2>&1 || rc=$?
  if [[ -n "$keep" ]]; then cp "$log" "$keep.log"; echo "$rc" >"$keep.rc"; fi
}

cd "$REPO_ROOT"
if [[ "${TIR_CENSUS_PARTIAL:-0}" == 1 && ( $WIDE -eq 0 || -z "${TIR_CENSUS_STATE:-}" ) ]]; then
  echo "TIR_CENSUS_PARTIAL=1 needs --wide and TIR_CENSUS_STATE" >&2; exit 2
fi
if [[ "${TIR_CENSUS_PARTIAL:-0}" != 1 ]]; then
for f in "${FILES[@]}"; do
  log="$OUT/log.txt"
  "$LYRIC" build --verify-ir --target "$(target_of "$f")" "$f" -o "$OUT/out.dll" >"$log" 2>&1
  rc=$?
  if ! grep -q '^TIR build census' "$log" && [[ $rc -ne 0 ]]; then unchecked+=("$f"); fi
  absorb_log stdlib-tests "$f" "$log" "$rc"
done

echo "TIR census over ${#FILES[@]} file(s): $built of $total function bodies built, $((total - built)) not yet (I0002), $i0003 I0003 diagnostic(s)"
if [[ -s "$OUT/bodies.stdlib-tests" ]]; then
  read -r ub bb < <(unique_bodies stdlib-tests | head -1)
  echo "  unique bodies: $bb of $ub built (a body shared by several programs counted once)"
fi
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
# The unique-body counts rest on the `TIR body` lines (D474); if the checker stops printing
# them the counts would silently fall back to nothing, so their absence is a failure.
if ! compgen -G "$OUT/bodies.*" >/dev/null; then
  echo "TIR census: no 'TIR body' line in any build output (LYRIC_TIR_CENSUS_BODIES=1)" >&2
  exit 1
fi
gate_rc=0
if [[ $i0003 -gt 0 || ${#unchecked[@]} -gt 0 ]]; then gate_rc=1; fi
# A call that leaves out an argument another package's function or record declares (D482).
bash "$REPO_ROOT/scripts/ci/tir-foreign-defaults-e2e.sh" "$LYRIC" || gate_rc=1
# Source shapes the builder must build (D483).
bash "$REPO_ROOT/scripts/ci/tir-builder-shapes-e2e.sh" "$LYRIC" || gate_rc=1
fi

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

# TIR_CENSUS_AREAS picks the wide areas (default all three).  A self-test that fails the
# ordinary build because it imports compiler packages is judged by running it under `lyric
# test` (TIR_CENSUS_LINKED=0 disables that; about 25 s each).  TIR_CENSUS_SELFTESTS="a.l b.l"
# replaces the self-test list (for a check of one change; its entries are split on spaces, so a
# path with a space is not supported).
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
run_cached "compiler-driver" 3000 env LYRIC_VERIFY_IR=1 "$LYRIC" --internal-perpackage-build "$OUT/compiler-driver/driver.l" "$OUT/compiler-out" --target dotnet
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
  run_cached "st-$f" 600 "$LYRIC" build --verify-ir --target "$(target_of "$f")" "$f" -o "$OUT/st.dll"
  if ! grep -q '^TIR build census' "$log" && [[ "${TIR_CENSUS_LINKED:-1}" == 1 ]] && grep -q '@test_module' "$f"; then
    # A @test_module that imports compiler packages builds only through `lyric test`, which
    # links them as restored dependencies; the census line is the same.  The tests run too
    # (about 25 s each), so CI, which leaves the self-tests area out, is unaffected, and
    # TIR_CENSUS_LINKED=0 turns it off.  A program that is not a @test_module has no such
    # path of its own and goes through `lyric run` below (D523).
    # target_of answers native only for two named stdlib tests, never for a compiler self-test.
    run_cached "stl-$f" 600 env LYRIC_VERIFY_IR=1 LYRIC_TIR_CENSUS_BODIES=1 "$LYRIC" test --target "$(target_of "$f")" "$f"
  elif ! grep -q '^TIR build census' "$log" && [[ "${TIR_CENSUS_LINKED:-1}" == 1 ]] && grep -q '^func main' "$f"; then
    # A `func main` self-test that imports compiler packages (the numbered
    # lyric-compiler/msil/msil_self_test_m*.l and lyric-compiler/jvm/self_test_b*.l programs)
    # runs through `LYRIC_LOAD_COMPILER=1 lyric run`, the path
    # scripts/run-numbered-self-tests.sh judges it by (docs/59 §9.5 H8).  The checker's census
    # lines are the same; the program runs too (about 12 s each), and its own pass or fail is
    # that script's business, so only the census lines are read here.
    run_cached "str-$f" 600 env LYRIC_LOAD_COMPILER=1 LYRIC_VERIFY_IR=1 LYRIC_TIR_CENSUS_BODIES=1 "$LYRIC" run "$f"
  fi
  absorb_log self-tests "$f" "$log" "$rc"
done < <(if [[ -n "${TIR_CENSUS_SELFTESTS:-}" ]]; then tr ' ' '\n' <<<"$TIR_CENSUS_SELFTESTS"; else find lyric-compiler -name '*self_test*.l' -not -path '*/testdata/*' | sort; fi)
fi

echo
echo "Wide TIR census (counts only, not gated):"
for area in stdlib-tests compiler ecosystem self-tests; do
  tried="${a_tried[$area]:-0}"
  if [[ "$tried" -eq 0 ]]; then
    echo "  [$area] not run here (TIR_CENSUS_AREAS=${TIR_CENSUS_AREAS:-compiler ecosystem self-tests}); its bodies are not in these totals"
    continue
  fi
  echo "  [$area] ${a_built[$area]:-0} of ${a_total[$area]:-0} bodies built over all builds, ${a_i0003[$area]:-0} I0003; ${a_judged[$area]:-0} of $tried build(s) judged"
  if [[ -s "$OUT/bodies.$area" ]]; then
    mapfile -t ub < <(unique_bodies "$area")
    read -r utotal ubuilt <<<"${ub[0]}"
    echo "    unique bodies: $ubuilt of $utotal built, $((utotal - ubuilt)) not yet (I0002)"
    # A kind line is `<count> <kind>TAB<site>`: the count is its first word and the kind
    # name must hold no tab.  (The raw `kind` line the checker prints is pinned by
    # tir_build_self_test.l: five tab-separated fields.)
    [[ ${#ub[@]} -gt 1 ]] && printf '%s\n' "${ub[@]:1}" | sort -n -r | head -15 | while IFS=$'\t' read -r head site; do
      echo "    I0002 kind ${head#* }: ${head%% *} (e.g. ${site})"
    done
  fi
  if [[ -n "${a_unchecked[$area]:-}" ]]; then
    echo "    unchecked builds: $(wc -w <<<"${a_unchecked[$area]}")"
    # shellcheck disable=SC2086
    printf '      %s\n' ${a_unchecked[$area]} | head -10
  fi
done
if [[ "${TIR_CENSUS_PARTIAL:-0}" == 1 ]]; then
  echo "  partial: $partial_missing wide build(s) had no kept result and are not counted"
  exit 0
fi
exit $gate_rc
