#!/usr/bin/env bash
# run-numbered-self-tests.sh — run the numbered backend self-test corpus
# (docs/59 §9.5 H8: the ~215 plain-`func main` test programs that lost their
# runner when the F# Expecto host was deleted).
#
#   lyric-compiler/msil/msil_self_test_m<N>.l   (--target msil set)
#   lyric-compiler/jvm/self_test_b<N>.l         (--target jvm set)
#
# Both sets are HOST programs: they import `Msil.*` / `Jvm.*` emission-library
# packages and run on the dotnet host (the jvm set builds .class/.jar bytes
# and validates them structurally — it does not itself execute under java).
# Each file is executed via `LYRIC_LOAD_COMPILER=1 lyric run <file>`, the
# canonical path for plain-main programs that import compiler packages (the
# linked-compiler-DLL fast path exists only for `@test_module` + `lyric test`).
#
# Pass criterion per file: the program exits 0 AND prints no `<label>=false`
# check line. Every numbered test reports its checks as `<label>=true` /
# `<label>=false` println lines (or panics, which is a non-zero exit).
#
# Usage:
#   scripts/run-numbered-self-tests.sh --target msil|jvm [options] [file ...]
#
# Options:
#   --target msil|jvm   which corpus to run (required unless explicit files given)
#   --jobs N            parallel workers (default: nproc)
#   --shard K/N         run only the K-th of N interleaved shards (1-based);
#                       used by CI to split a set across parallel jobs
#   --lyric PATH        lyric binary (default: ./bin/lyric)
#   --include-excluded  also run the files in the exclusion list below
#   file ...            run exactly these files (still applies the pass criterion)
#
# Exit status: 0 when every selected file passes, 1 otherwise.
set -euo pipefail

# ── Exclusion list ────────────────────────────────────────────────────────────
# Files excluded from the gate, each with a one-line reason. Do NOT add entries
# here to quiet a failure without a tracked justification: an entry is either a
# real compiler/emitter regression documented in the audit trail (fix the
# compiler, then remove the entry) or a bit-rotted test pending repair.
# Currently EMPTY: the docs/59 H8 triage repaired every bit-rotted file in
# place (missing Msil.Kernel/Jvm.Kernel imports, m75's wide-encoding
# expectation, b3's block-in-named-arg form, b13's deleted-harness fixture),
# so the whole corpus gates.
EXCLUDED=(
)

# ── Wired-elsewhere list ──────────────────────────────────────────────────────
# Numbered files that already have dedicated CI steps (native `lyric test` /
# `lyric run` wiring in .github/workflows/ci.yml); they are not part of the
# orphaned corpus this script gates.
WIRED_ELSEWHERE=(
  lyric-compiler/msil/msil_self_test_m2a.l
  lyric-compiler/msil/msil_self_test_m2b.l
  lyric-compiler/msil/msil_self_test_m2c.l
  lyric-compiler/msil/msil_self_test_m2d.l
  lyric-compiler/msil/msil_self_test_m85.l
  lyric-compiler/msil/msil_self_test_m86.l
  lyric-compiler/msil/msil_self_test_m87.l
  lyric-compiler/msil/msil_self_test_m88.l
  lyric-compiler/msil/msil_self_test_m89.l
)

TARGET=""
JOBS="$(nproc)"
SHARD=""
LYRIC_BIN="./bin/lyric"
INCLUDE_EXCLUDED=0
EXPLICIT_FILES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)           TARGET="${2:?--target needs msil|jvm}"; shift 2 ;;
    --jobs)             JOBS="${2:?--jobs needs a number}"; shift 2 ;;
    --shard)            SHARD="${2:?--shard needs K/N}"; shift 2 ;;
    --lyric)            LYRIC_BIN="${2:?--lyric needs a path}"; shift 2 ;;
    --include-excluded) INCLUDE_EXCLUDED=1; shift ;;
    -h|--help)          sed -n '2,40p' "$0"; exit 0 ;;
    -*)                 echo "unknown option: $1" >&2; exit 2 ;;
    *)                  EXPLICIT_FILES+=("$1"); shift ;;
  esac
done

if [[ ! -x "$LYRIC_BIN" ]]; then
  echo "error: lyric binary not found or not executable at $LYRIC_BIN (build with 'make lyric' or pass --lyric)" >&2
  exit 2
fi

contains() {
  local needle="$1"; shift
  local x
  for x in "$@"; do [[ "$x" == "$needle" ]] && return 0; done
  return 1
}

# ── File selection ────────────────────────────────────────────────────────────
FILES=()
if [[ ${#EXPLICIT_FILES[@]} -gt 0 ]]; then
  FILES=("${EXPLICIT_FILES[@]}")
else
  case "$TARGET" in
    msil) mapfile -t candidates < <(ls lyric-compiler/msil/msil_self_test_m*.l | sort -V) ;;
    jvm)  mapfile -t candidates < <(ls lyric-compiler/jvm/self_test_b*.l | sort -V) ;;
    *)    echo "error: --target msil|jvm is required (or pass explicit files)" >&2; exit 2 ;;
  esac
  skipped_excluded=()
  for f in "${candidates[@]}"; do
    if contains "$f" "${WIRED_ELSEWHERE[@]+"${WIRED_ELSEWHERE[@]}"}"; then
      continue
    fi
    if [[ $INCLUDE_EXCLUDED -eq 0 ]] && contains "$f" "${EXCLUDED[@]+"${EXCLUDED[@]}"}"; then
      skipped_excluded+=("$f")
      continue
    fi
    FILES+=("$f")
  done
  if [[ ${#skipped_excluded[@]} -gt 0 ]]; then
    echo "excluded from gate (${#skipped_excluded[@]} files; see exclusion list in $0 for reasons):"
    printf '  EXCLUDED %s\n' "${skipped_excluded[@]}"
  fi
fi

if [[ -n "$SHARD" ]]; then
  if [[ ! "$SHARD" =~ ^([0-9]+)/([0-9]+)$ ]]; then
    echo "error: --shard must be K/N (e.g. 1/2)" >&2; exit 2
  fi
  k="${BASH_REMATCH[1]}"; n="${BASH_REMATCH[2]}"
  if (( k < 1 || k > n )); then
    echo "error: shard index $k out of range 1..$n" >&2; exit 2
  fi
  sharded=()
  for i in "${!FILES[@]}"; do
    if (( i % n == k - 1 )); then sharded+=("${FILES[$i]}"); fi
  done
  FILES=("${sharded[@]}")
fi

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "error: no test files selected" >&2
  exit 2
fi

echo "running ${#FILES[@]} numbered self-tests (target=${TARGET:-explicit}, jobs=$JOBS, lyric=$LYRIC_BIN)"

RESULTS_DIR="$(mktemp -d)"
trap 'rm -rf "$RESULTS_DIR"' EXIT
export RESULTS_DIR LYRIC_BIN

# ── Per-file worker ───────────────────────────────────────────────────────────
run_one() {
  set -uo pipefail
  local f="$1"
  local name; name="$(basename "$f" .l)"
  local log="$RESULTS_DIR/$name.log"
  # Run an isolated copy: concurrent `lyric run` invocations on siblings in
  # the same source directory would share one `.lyric-run/` output dir and
  # race on the stdlib-DLL co-location copies. Compiler/stdlib source
  # discovery is unaffected — it walks up from the lyric binary's own base
  # directory, which stays inside the repo.
  local workdir="$RESULTS_DIR/$name.work"
  mkdir -p "$workdir"
  cp "$f" "$workdir/$name.l"
  local start; start=$(date +%s)
  local rc=0
  # LYRIC_LOAD_COMPILER=1: compile the program's Msil.*/Jvm.* compiler-package
  # closure from source in-process (plain-main programs cannot link the staged
  # compiler bundle the way `lyric test` @test_modules do).
  LYRIC_LOAD_COMPILER=1 "$LYRIC_BIN" run "$workdir/$name.l" >"$log" 2>&1 || rc=$?
  rm -rf "$workdir"
  local elapsed=$(( $(date +%s) - start ))
  local verdict="PASS"
  if [[ $rc -ne 0 ]]; then
    verdict="FAIL(exit=$rc)"
  elif grep -qE '^[A-Za-z0-9_]+=false$' "$log"; then
    verdict="FAIL(check=false)"
  fi
  if [[ "$verdict" == "PASS" ]]; then
    echo "PASS  ${elapsed}s  $f"
  else
    echo "FAIL  ${elapsed}s  $f  [$verdict]"
    {
      echo "===== $f ($verdict) ====="
      # `lyric run` build lines are noise on failure output; keep the tail,
      # which carries the diagnostics / failing check lines.
      tail -30 "$log"
    } >> "$RESULTS_DIR/$name.fail"
  fi
}
export -f run_one

# `|| true`: pass/fail accounting is via the .fail files, so a worker-level
# error must not abort the pipeline before the summary reports it.
printf '%s\n' "${FILES[@]}" | xargs -P "$JOBS" -I {} bash -c 'run_one "$@"' _ {} || true

# ── Summary ───────────────────────────────────────────────────────────────────
fails=("$RESULTS_DIR"/*.fail)
if [[ -e "${fails[0]}" ]]; then
  echo
  echo "──── failure details ────"
  cat "$RESULTS_DIR"/*.fail
  echo
  n_fail=$(ls "$RESULTS_DIR"/*.fail | wc -l)
  echo "RESULT: $(( ${#FILES[@]} - n_fail ))/${#FILES[@]} passed, $n_fail failed"
  exit 1
fi
echo "RESULT: ${#FILES[@]}/${#FILES[@]} passed"
