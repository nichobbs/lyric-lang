#!/usr/bin/env bash
# manual-test.sh — end-to-end production-readiness smoke for the Lyric ecosystem.
#
# Pipeline:
#   1.  env-check              — record SDK / runtime versions (advisory)
#   2.  bootstrap-build        — `dotnet build bootstrap/Bootstrap.sln`
#   3.  bootstrap-tests        — Expecto suites (lexer/parser/tc/emitter/cli)
#   4.  bootstrap-publish      — publish a `lyric` binary used by later stages
#   5.  repro-bootstrap        — scripts/bootstrap.sh --stage 2 (byte-equal)
#   6.  stdlib-build           — `lyric build` over lyric-stdlib/lyric.toml
#   7.  stdlib-tests           — `lyric test` on every lyric-stdlib/tests/*_tests.l
#   8.  ecosystem-build-dotnet — every other lyric-*/lyric.toml (--target dotnet)
#   9.  ecosystem-build-jvm    — same with --target jvm
#  10.  ecosystem-tests        — `lyric test` on every lyric-*/tests/*_tests.l
#  11.  examples-build-dotnet  — single-file .l + multi-file examples/*/lyric.toml
#  12.  examples-build-jvm     — same with --target jvm
#  13.  examples-tests         — `lyric test` on every examples/*/tests/*_tests.l
#  14.  fmt-check              — `lyric fmt --check` over every tracked .l file
#  15.  lint                   — `lyric lint` over every tracked .l file
#  16.  prove                  — `lyric prove` on verifier-marked examples
#  17.  gap-analysis           — examples without tests, kernel stub no-ops,
#                                libraries without tests/manifest, TODO/FIXME
#
# Output: .manual-test-report/
#   report.md          human-readable summary
#   summary.json       machine-readable summary
#   env.txt            captured environment
#   logs/<stage>.log   per-stage stdout+stderr
#   gaps/              per-gap-category text reports
#
# Usage:
#   scripts/manual-test.sh                run every stage, report at the end
#   scripts/manual-test.sh --fail-fast    stop on first failure
#   scripts/manual-test.sh --skip-jvm     skip every JVM target stage
#   scripts/manual-test.sh --skip-prove   skip the verifier stage
#   scripts/manual-test.sh --skip-repro   skip the 3-stage reproducibility build
#   scripts/manual-test.sh --only <name>  run only the named stage
#   scripts/manual-test.sh --list         list stage names and exit
#   scripts/manual-test.sh --report-dir D write reports under D instead of default

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# ── Argument parsing ─────────────────────────────────────────────────────────

FAIL_FAST=0
SKIP_JVM=0
SKIP_PROVE=0
SKIP_REPRO=0
ONLY_STAGE=""
REPORT_DIR="$REPO_ROOT/.manual-test-report"
LIST_STAGES=0

STAGES=(
  env-check
  bootstrap-build
  bootstrap-tests
  bootstrap-publish
  repro-bootstrap
  stdlib-build
  stdlib-tests
  ecosystem-build-dotnet
  ecosystem-build-jvm
  ecosystem-tests
  examples-build-dotnet
  examples-build-jvm
  examples-tests
  fmt-check
  lint
  prove
  gap-analysis
)

while [ $# -gt 0 ]; do
  case "$1" in
    --fail-fast)   FAIL_FAST=1; shift ;;
    --skip-jvm)    SKIP_JVM=1; shift ;;
    --skip-prove)  SKIP_PROVE=1; shift ;;
    --skip-repro)  SKIP_REPRO=1; shift ;;
    --only)        ONLY_STAGE="$2"; shift 2 ;;
    --report-dir)  REPORT_DIR="$2"; shift 2 ;;
    --list)        LIST_STAGES=1; shift ;;
    -h|--help)
      sed -n '2,40p' "$0"
      exit 0 ;;
    *) echo "manual-test: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

if [ "$LIST_STAGES" = "1" ]; then
  printf '%s\n' "${STAGES[@]}"
  exit 0
fi

if [ -n "$ONLY_STAGE" ]; then
  found=0
  for s in "${STAGES[@]}"; do
    [ "$s" = "$ONLY_STAGE" ] && found=1
  done
  if [ "$found" = "0" ]; then
    echo "manual-test: --only '$ONLY_STAGE' is not a known stage. Use --list." >&2
    exit 2
  fi
fi

LOG_DIR="$REPORT_DIR/logs"
GAP_DIR="$REPORT_DIR/gaps"
mkdir -p "$LOG_DIR" "$GAP_DIR"

# Wipe previous report contents so stale results don't bleed into this run.
rm -f "$LOG_DIR"/*.log "$GAP_DIR"/*.txt 2>/dev/null || true

RESULTS_TSV="$REPORT_DIR/results.tsv"
: > "$RESULTS_TSV"

# ── Stage tracking helpers ───────────────────────────────────────────────────

record_stage() {
  # NAME  STATUS  DURATION_SEC  NOTES
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$RESULTS_TSV"
}

should_skip() {
  local name="$1"
  if [ -n "$ONLY_STAGE" ] && [ "$name" != "$ONLY_STAGE" ]; then
    record_stage "$name" "SKIP" 0 "filtered by --only"
    return 0
  fi
  case "$name" in
    repro-bootstrap)        [ "$SKIP_REPRO" = "1" ] && { record_stage "$name" "SKIP" 0 "--skip-repro"; return 0; } ;;
    ecosystem-build-jvm|examples-build-jvm)
                            [ "$SKIP_JVM"   = "1" ] && { record_stage "$name" "SKIP" 0 "--skip-jvm";   return 0; } ;;
    prove)                  [ "$SKIP_PROVE" = "1" ] && { record_stage "$name" "SKIP" 0 "--skip-prove"; return 0; } ;;
  esac
  return 1
}

run_stage() {
  local name="$1" desc="$2"
  shift 2
  if should_skip "$name"; then
    echo "[$name] SKIP — $(grep -m1 "^${name}	" "$RESULTS_TSV" | cut -f4)"
    return 0
  fi
  echo
  echo "======================================================================"
  echo "  [$name] $desc"
  echo "======================================================================"
  local start_ts end_ts dur rc
  start_ts=$(date +%s)
  local log="$LOG_DIR/${name}.log"
  rc=0
  # Braces (not a subshell) so stages can export state (notably LYRIC_BIN
  # from bootstrap-publish) to later stages.  Internal `cd`s inside each
  # stage use their own `(  )` subshells to stay isolated.
  { "$@"; } >"$log" 2>&1 || rc=$?
  end_ts=$(date +%s)
  dur=$((end_ts - start_ts))
  if [ $rc -eq 0 ]; then
    record_stage "$name" "OK"   "$dur" ""
    echo "[$name] OK (${dur}s)  log: $log"
  else
    record_stage "$name" "FAIL" "$dur" "exit=$rc"
    echo "[$name] FAIL exit=$rc (${dur}s)  log: $log"
    tail -n 30 "$log" | sed 's/^/    | /'
    if [ "$FAIL_FAST" = "1" ]; then
      echo "[manual-test] --fail-fast: stopping."
      generate_reports
      exit $rc
    fi
  fi
}

# ── Lyric invocation helper ──────────────────────────────────────────────────
# `bootstrap-publish` sets LYRIC_BIN; until then we run the CLI via dotnet.

LYRIC_BIN=""
lyric() {
  if [ -n "$LYRIC_BIN" ]; then
    "$LYRIC_BIN" "$@"
  else
    dotnet run --project "$REPO_ROOT/bootstrap/src/Lyric.Cli/Lyric.Cli.fsproj" -c Release --no-build -- "$@"
  fi
}

# ── Stage implementations ────────────────────────────────────────────────────

stage_env_check() {
  echo "uname:   $(uname -srm)"
  echo "dotnet:  $(dotnet --version 2>&1 || echo MISSING)"
  echo "java:    $(java -version 2>&1 | head -1 || echo MISSING)"
  echo "javac:   $(javac -version 2>&1 || echo MISSING)"
  echo "z3:      $(z3 --version 2>&1 || echo MISSING)"
  echo "mvn:     $(mvn --version 2>&1 | head -1 || echo MISSING)"
  echo "git:     $(git --version 2>&1 || echo MISSING)"
  echo "branch:  $(git rev-parse --abbrev-ref HEAD 2>&1)"
  echo "head:    $(git rev-parse --short HEAD 2>&1)"
  echo "PWD:     $REPO_ROOT"
  return 0
}

stage_bootstrap_build() {
  dotnet build "$REPO_ROOT/bootstrap/Bootstrap.sln" -c Release --nologo -v m
}

stage_bootstrap_tests() {
  local rc=0
  local proj
  for proj in Lyric.Lexer.Tests Lyric.Parser.Tests Lyric.TypeChecker.Tests Lyric.Emitter.Tests Lyric.Cli.Tests; do
    local path="$REPO_ROOT/bootstrap/tests/$proj"
    if [ ! -d "$path" ]; then
      echo "[bootstrap-tests] missing project: $proj — skipping"
      continue
    fi
    echo
    echo "--- $proj ---"
    if ! dotnet run --project "$path" -c Release --no-build; then
      rc=1
    fi
  done
  return $rc
}

stage_bootstrap_publish() {
  local out="$REPORT_DIR/lyric-bin"
  rm -rf "$out"
  mkdir -p "$out"
  dotnet publish "$REPO_ROOT/bootstrap/src/Lyric.Cli/Lyric.Cli.fsproj" \
    -c Release -o "$out" --nologo -v q
  if [ -f "$out/lyric" ]; then
    chmod +x "$out/lyric"
    LYRIC_BIN="$out/lyric"
  elif [ -f "$out/lyric.dll" ]; then
    cat > "$out/lyric" <<WRAPPER
#!/usr/bin/env bash
exec dotnet "$out/lyric.dll" "\$@"
WRAPPER
    chmod +x "$out/lyric"
    LYRIC_BIN="$out/lyric"
  else
    echo "publish produced no lyric binary" >&2
    return 1
  fi
  echo "[bootstrap-publish] LYRIC_BIN=$LYRIC_BIN"
  "$LYRIC_BIN" --version
}

stage_repro_bootstrap() {
  bash "$REPO_ROOT/scripts/bootstrap.sh" --stage 2
}

# Walk every lyric-*/ dir except the ones we treat specially.
ecosystem_dirs() {
  find "$REPO_ROOT" -maxdepth 1 -type d -name 'lyric-*' \
    | sort \
    | while read -r d; do
        case "$(basename "$d")" in
          lyric-stdlib|lyric-compiler|lyric-vscode) continue ;;
          *) [ -f "$d/lyric.toml" ] && echo "$d" ;;
        esac
      done
}

stage_stdlib_build() {
  ( cd "$REPO_ROOT/lyric-stdlib" && lyric build --manifest lyric.toml )
}

stage_stdlib_tests() {
  local rc=0
  local tf
  while IFS= read -r tf; do
    echo
    echo "--- $tf ---"
    if ! lyric test "$tf"; then
      rc=1
    fi
  done < <(find "$REPO_ROOT/lyric-stdlib/tests" -maxdepth 1 -name '*_tests.l' | sort)
  return $rc
}

build_one_manifest() {
  local manifest="$1" target="$2"
  local dir
  dir="$(dirname "$manifest")"
  ( cd "$dir" \
      && lyric restore --manifest lyric.toml 2>/dev/null \
      ; lyric build --manifest lyric.toml --target "$target"
  )
}

stage_ecosystem_build_dotnet() {
  local rc=0
  local d
  while IFS= read -r d; do
    echo
    echo "--- $(basename "$d") (dotnet) ---"
    if ! build_one_manifest "$d/lyric.toml" dotnet; then
      rc=1
    fi
  done < <(ecosystem_dirs)
  return $rc
}

stage_ecosystem_build_jvm() {
  local rc=0
  local d
  while IFS= read -r d; do
    echo
    echo "--- $(basename "$d") (jvm) ---"
    if ! build_one_manifest "$d/lyric.toml" jvm; then
      rc=1
    fi
  done < <(ecosystem_dirs)
  return $rc
}

stage_ecosystem_tests() {
  local rc=0
  local d tf
  while IFS= read -r d; do
    [ -d "$d/tests" ] || continue
    while IFS= read -r tf; do
      echo
      echo "--- $tf ---"
      if ! ( cd "$d" && lyric test "$tf" ); then
        rc=1
      fi
    done < <(find "$d/tests" -maxdepth 2 -name '*_tests.l' | sort)
  done < <(ecosystem_dirs)
  return $rc
}

# Examples that have NO `main` function and only exist for the verifier are
# skipped from the build stages.  Keep this list in sync with examples/README.md.
EXAMPLE_VERIFIER_ONLY=(
  examples/prove_demo.l
  examples/token_bucket_proof.l
)

is_verifier_only() {
  local rel="${1#"$REPO_ROOT/"}"
  local item
  for item in "${EXAMPLE_VERIFIER_ONLY[@]}"; do
    [ "$rel" = "$item" ] && return 0
  done
  return 1
}

build_examples_for_target() {
  local target="$1"
  local rc=0
  local f
  for f in "$REPO_ROOT"/examples/*.l; do
    [ -f "$f" ] || continue
    if is_verifier_only "$f"; then
      echo "--- $(basename "$f") ($target) — SKIP (verifier-only)"
      continue
    fi
    echo
    echo "--- $(basename "$f") ($target) ---"
    if ! lyric build "$f" --target "$target"; then
      rc=1
    fi
  done
  local m
  for m in "$REPO_ROOT"/examples/*/lyric.toml; do
    [ -f "$m" ] || continue
    echo
    echo "--- $(dirname "${m#"$REPO_ROOT/"}") ($target) ---"
    if ! build_one_manifest "$m" "$target"; then
      rc=1
    fi
  done
  return $rc
}

stage_examples_build_dotnet() { build_examples_for_target dotnet; }
stage_examples_build_jvm()    { build_examples_for_target jvm; }

stage_examples_tests() {
  local rc=0
  local m d tf
  for m in "$REPO_ROOT"/examples/*/lyric.toml; do
    [ -f "$m" ] || continue
    d="$(dirname "$m")"
    [ -d "$d/tests" ] || continue
    while IFS= read -r tf; do
      echo
      echo "--- ${tf#"$REPO_ROOT/"} ---"
      if ! ( cd "$d" && lyric test "$tf" ); then
        rc=1
      fi
    done < <(find "$d/tests" -maxdepth 2 -name '*_tests.l' | sort)
  done
  return $rc
}

# Files we never want to fmt/lint: tracked-but-generated outputs, the bootstrap
# tree (F# only), and any cache dirs.
tracked_lyric_files() {
  git ls-files -- '*.l' \
    | grep -vE '^(\.bootstrap|bootstrap/|book/|docs/|examples/.*/openapi\.l$)' \
    | sort
}

stage_fmt_check() {
  local rc=0 count=0 fail=0 f
  while IFS= read -r f; do
    count=$((count + 1))
    if ! lyric fmt "$f" --check >/dev/null 2>&1; then
      fail=$((fail + 1))
      echo "FMT  $f"
    fi
  done < <(tracked_lyric_files)
  echo
  echo "[fmt-check] checked=$count unformatted=$fail"
  [ "$fail" -gt 0 ] && rc=1
  return $rc
}

stage_lint() {
  local rc=0 count=0 fail=0 f
  while IFS= read -r f; do
    count=$((count + 1))
    if ! lyric lint "$f" --error-on-warning >/dev/null 2>&1; then
      fail=$((fail + 1))
      echo "LINT $f"
    fi
  done < <(tracked_lyric_files)
  echo
  echo "[lint] checked=$count failures=$fail (with --error-on-warning)"
  [ "$fail" -gt 0 ] && rc=1
  return $rc
}

PROVE_TARGETS=(
  examples/prove_demo.l
  examples/token_bucket_proof.l
)

stage_prove() {
  local rc=0
  local rel
  for rel in "${PROVE_TARGETS[@]}"; do
    echo
    echo "--- lyric prove $rel ---"
    if ! lyric prove "$REPO_ROOT/$rel" --verbose; then
      rc=1
    fi
  done
  return $rc
}

# ── Gap analysis (advisory; never fails the run) ─────────────────────────────

gap_examples_without_tests() {
  local out="$GAP_DIR/examples-without-tests.txt"
  : > "$out"
  local d
  for d in "$REPO_ROOT"/examples/*/; do
    [ -d "$d" ] || continue
    [ -f "$d/lyric.toml" ] || continue
    if [ ! -d "$d/tests" ] || ! find "$d/tests" -maxdepth 2 -name '*_tests.l' | grep -q .; then
      echo "${d#"$REPO_ROOT/"}" >> "$out"
    fi
  done
  local n
  n=$(wc -l < "$out" 2>/dev/null || echo 0)
  echo "examples-without-tests: $n entries → $out"
}

gap_libs_without_tests_or_toml() {
  local out="$GAP_DIR/libs-without-tests-or-toml.txt"
  : > "$out"
  local d name
  for d in "$REPO_ROOT"/lyric-*/; do
    name="$(basename "$d")"
    case "$name" in
      lyric-vscode) continue ;;
    esac
    local has_toml=0 has_tests=0
    [ -f "$d/lyric.toml" ] && has_toml=1
    [ -d "$d/tests" ] && find "$d/tests" -maxdepth 2 -name '*_tests.l' | grep -q . && has_tests=1
    if [ $has_toml = 0 ] || [ $has_tests = 0 ]; then
      printf '%s\ttoml=%d\ttests=%d\n' "$name" "$has_toml" "$has_tests" >> "$out"
    fi
  done
  local n
  n=$(wc -l < "$out" 2>/dev/null || echo 0)
  echo "libs-without-tests-or-toml: $n entries → $out"
}

gap_kernel_stubs() {
  # Mirrors scripts/audit-kernel-stubs.sh's pattern set, but scans the working
  # tree (not the diff vs main) so it lists every stub currently shipped.
  local out="$GAP_DIR/kernel-stubs.txt"
  : > "$out"
  local patterns=(
    '= Ok\(0\)$'
    '= Ok\(""\)$'
    '= Ok\(\(\)\)$'
    '= Ok\(false\)$'
    '= Err\("[^"]*not linked"\)'
    ': Unit = \(\)$'
  )
  local joined
  joined=$(IFS='|'; echo "${patterns[*]}")
  find "$REPO_ROOT" -path "*/_kernel/net/*.l" \
    -not -path "*/.bootstrap/*" \
    -not -path "*/bin/*" -not -path "*/obj/*" \
    | sort \
    | while read -r f; do
        grep -nE "^pub func.*($joined)" "$f" 2>/dev/null \
          | sed "s|^|${f#"$REPO_ROOT/"}:|"
      done >> "$out"
  local n
  n=$(wc -l < "$out" 2>/dev/null || echo 0)
  echo "kernel-stubs: $n stub bodies → $out"
}

gap_todo_fixme_census() {
  local out="$GAP_DIR/todo-fixme.txt"
  : > "$out"
  # Counts per top-level dir; per-line listing kept under the count summary.
  git grep -nE 'TODO|FIXME|XXX|HACK' -- '*.l' '*.fs' 2>/dev/null \
    | awk -F: '{ split($1, a, "/"); print a[1] }' \
    | sort | uniq -c | sort -rn \
    >> "$out" || true
  echo "--- detailed listing ---" >> "$out"
  git grep -nE 'TODO|FIXME|XXX|HACK' -- '*.l' '*.fs' 2>/dev/null >> "$out" || true
  local total
  total=$(grep -cE 'TODO|FIXME|XXX|HACK' "$out" 2>/dev/null || echo 0)
  echo "todo-fixme census: $total markers → $out"
}

stage_gap_analysis() {
  gap_examples_without_tests
  gap_libs_without_tests_or_toml
  gap_kernel_stubs
  gap_todo_fixme_census
  return 0
}

# ── Report generation ────────────────────────────────────────────────────────

generate_reports() {
  local md="$REPORT_DIR/report.md"
  local js="$REPORT_DIR/summary.json"
  local env_file="$REPORT_DIR/env.txt"

  # Capture environment snapshot.
  {
    echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Repo HEAD: $(git rev-parse HEAD 2>&1)"
    echo "Branch:    $(git rev-parse --abbrev-ref HEAD 2>&1)"
    echo "uname:     $(uname -srm)"
    echo "dotnet:    $(dotnet --version 2>&1 || echo MISSING)"
    echo "java:      $(java -version 2>&1 | head -1 || echo MISSING)"
    echo "z3:        $(z3 --version 2>&1 || echo MISSING)"
    echo "mvn:       $(mvn --version 2>&1 | head -1 || echo MISSING)"
  } > "$env_file"

  # ---- report.md ----
  {
    echo "# Lyric manual-test report"
    echo
    echo "_Generated $(date -u +%Y-%m-%dT%H:%M:%SZ)_"
    echo
    echo "Branch: \`$(git rev-parse --abbrev-ref HEAD 2>&1)\`"
    echo "Head:   \`$(git rev-parse --short HEAD 2>&1)\`"
    echo
    echo "## Pipeline result"
    echo
    echo "| Stage | Status | Duration | Notes |"
    echo "|-------|--------|----------|-------|"
    local name status dur notes
    while IFS=$'\t' read -r name status dur notes; do
      printf '| %s | %s | %ss | %s |\n' "$name" "$status" "$dur" "${notes:--}"
    done < "$RESULTS_TSV"
    echo
    echo "Per-stage logs: \`logs/<stage>.log\`"
    echo
    echo "## Gap analysis"
    echo
    local gap label
    for gap in examples-without-tests libs-without-tests-or-toml kernel-stubs todo-fixme; do
      local f="$GAP_DIR/${gap}.txt"
      label="${gap//-/ }"
      if [ ! -f "$f" ]; then
        echo "### $label"
        echo
        echo "_Not produced this run._"
        echo
        continue
      fi
      local n
      n=$(wc -l < "$f" 2>/dev/null || echo 0)
      echo "### $label ($n entries)"
      echo
      echo "Full listing: \`gaps/${gap}.txt\`"
      echo
      echo '```'
      head -n 30 "$f" 2>/dev/null
      [ "$n" -gt 30 ] && echo "... (truncated; see file)"
      echo '```'
      echo
    done
    echo "## Environment"
    echo
    echo '```'
    cat "$env_file"
    echo '```'
  } > "$md"

  # ---- summary.json ----
  {
    echo '{'
    echo '  "generatedAt": "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'",'
    echo '  "branch": "'"$(git rev-parse --abbrev-ref HEAD 2>&1)"'",'
    echo '  "head": "'"$(git rev-parse HEAD 2>&1)"'",'
    echo '  "stages": ['
    local first=1
    local name status dur notes
    while IFS=$'\t' read -r name status dur notes; do
      [ $first = 1 ] && first=0 || echo ','
      printf '    {"name":"%s","status":"%s","durationSeconds":%s,"notes":"%s"}' \
        "$name" "$status" "$dur" "${notes//\"/\\\"}"
    done < "$RESULTS_TSV"
    echo
    echo '  ],'
    local total=0 ok=0 fail=0 skip=0
    while IFS=$'\t' read -r _ status _ _; do
      total=$((total+1))
      case "$status" in
        OK)   ok=$((ok+1))   ;;
        FAIL) fail=$((fail+1)) ;;
        SKIP) skip=$((skip+1)) ;;
      esac
    done < "$RESULTS_TSV"
    echo "  \"totals\": {\"total\": $total, \"ok\": $ok, \"fail\": $fail, \"skip\": $skip},"
    echo '  "gaps": {'
    local first2=1 g
    for g in examples-without-tests libs-without-tests-or-toml kernel-stubs todo-fixme; do
      [ $first2 = 1 ] && first2=0 || echo ','
      local f="$GAP_DIR/${g}.txt"
      local n=0
      [ -f "$f" ] && n=$(wc -l < "$f" 2>/dev/null || echo 0)
      printf '    "%s": %s' "$g" "$n"
    done
    echo
    echo '  }'
    echo '}'
  } > "$js"

  echo
  echo "===================================================================="
  echo "  Report written:"
  echo "    $md"
  echo "    $js"
  echo "    $env_file"
  echo "    $LOG_DIR/"
  echo "    $GAP_DIR/"
  echo "===================================================================="
}

# ── Pipeline ─────────────────────────────────────────────────────────────────

run_stage env-check              "Environment snapshot"                    stage_env_check
run_stage bootstrap-build        "F# bootstrap compiler (dotnet build)"    stage_bootstrap_build
run_stage bootstrap-tests        "Expecto test suites"                     stage_bootstrap_tests
run_stage bootstrap-publish      "Publish lyric binary"                    stage_bootstrap_publish
run_stage repro-bootstrap        "3-stage reproducibility bootstrap"       stage_repro_bootstrap
run_stage stdlib-build           "Build Lyric.Stdlib end-to-end"           stage_stdlib_build
run_stage stdlib-tests           "Run stdlib *_tests.l via lyric test"     stage_stdlib_tests
run_stage ecosystem-build-dotnet "Build every lyric-*/ for --target dotnet" stage_ecosystem_build_dotnet
run_stage ecosystem-build-jvm    "Build every lyric-*/ for --target jvm"   stage_ecosystem_build_jvm
run_stage ecosystem-tests        "Run lyric test for every lyric-*/tests/" stage_ecosystem_tests
run_stage examples-build-dotnet  "Build examples for --target dotnet"      stage_examples_build_dotnet
run_stage examples-build-jvm     "Build examples for --target jvm"         stage_examples_build_jvm
run_stage examples-tests         "Run lyric test for every example tests/" stage_examples_tests
run_stage fmt-check              "lyric fmt --check on tracked .l files"   stage_fmt_check
run_stage lint                   "lyric lint on tracked .l files"          stage_lint
run_stage prove                  "lyric prove on verifier examples"        stage_prove
run_stage gap-analysis           "Gap census (examples, kernel stubs, TODO)" stage_gap_analysis

generate_reports

# Exit non-zero if any non-skipped stage failed.
fail_count=$(grep -c '^[^	]*	FAIL	' "$RESULTS_TSV" 2>/dev/null || true)
fail_count=${fail_count:-0}
if [ "$fail_count" -gt 0 ]; then
  echo "[manual-test] $fail_count stage(s) failed."
  exit 1
fi
echo "[manual-test] All stages OK."
exit 0
