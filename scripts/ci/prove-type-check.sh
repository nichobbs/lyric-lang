#!/usr/bin/env bash
# `lyric prove` type-checks the program before it proves anything (#8227): a
# file or project the type checker rejects stops with the type checker's
# diagnostics and a non-zero exit, in the single-file, --manifest and --json
# modes, while its type-correct twin is proved.  Also: a quantifier's body
# keeps its side conditions (#8223) — a goal the verifier used to prove
# because it dropped them is refuted, and its guarded twin is proved.  And
# the --json summary counts every outcome (#8307), --proof-dir writes the
# obligations' SMT-LIB queries, and an option prove does not take is an
# error rather than a source path (#8309).
#
#   LYRIC_BIN=<lyric> bash scripts/ci/prove-type-check.sh
set -euo pipefail
lyric_bin="${LYRIC_BIN:?LYRIC_BIN must name the lyric binary}"
lyric_bin="$(cd "$(dirname "$lyric_bin")" && pwd)/$(basename "$lyric_bin")"
examples="$(cd "$(dirname "$0")/../.." && pwd)/examples"
tc="$examples/prove-type-check"
qs="$examples/prove-quantifier-sides"
js="$examples/prove-json-summary"
out="$(mktemp)"
err="$(mktemp)"
proofs="$(mktemp -d)"
trap 'rm -f "$out" "$err"; rm -rf "${proofs:?}"' EXIT

run() {
  local rc=0
  "$@" > "$out" 2> "$err" || rc=$?
  echo "$rc"
}

fail() {
  echo "FAIL: $1"
  echo "--- stdout"; cat "$out"
  echo "--- stderr"; cat "$err"
  exit 1
}

# A type error stops the proof: the build's diagnostic, the refusal, and no
# obligation attempted.
expect_type_error() {
  local label="$1" code="$2"; shift 2
  local rc
  rc="$(run "$@")"
  [ "$rc" -ne 0 ] || fail "$label: expected a non-zero exit"
  grep -q "error\[$code\]" "$err" || fail "$label: expected the type checker's $code"
  grep -q "fails the build's checks; no proof obligation was attempted" "$err" || fail "$label: expected the refusal"
  if grep -q "obligations discharged" "$out"; then
    fail "$label: no obligation may be attempted"
  fi
  echo "PASS: $label"
}

expect_proved() {
  local label="$1"; shift
  local rc
  rc="$(run "$@")"
  [ "$rc" -eq 0 ] || fail "$label: expected the proof to go through"
  grep -Eq "([0-9]+)/\1 obligations discharged" "$out" || fail "$label: expected every obligation discharged"
  echo "PASS: $label"
}

expect_type_error "ill-typed file" T0032 "$lyric_bin" prove "$tc/illtyped.l"
expect_type_error "ill-typed file, --explain" T0032 "$lyric_bin" prove --explain --goal 0 "$tc/illtyped.l"
expect_proved "well-typed file" "$lyric_bin" prove "$tc/welltyped.l"

# --json: the type checker's diagnostics are the document's, with no goals.
rc="$(run "$lyric_bin" prove --json "$tc/illtyped.l")"
[ "$rc" -ne 0 ] || fail "ill-typed file, --json: expected a non-zero exit"
grep -q '"code":"T0032","severity":"error"' "$out" || fail "ill-typed file, --json: expected T0032 among the diagnostics"
grep -q '"file":".*illtyped.l"' "$out" || fail "ill-typed file, --json: expected the diagnostic's file"
grep -q '"total": 0' "$out" || fail "ill-typed file, --json: expected no goals"
echo "PASS: ill-typed file, --json"
rc="$(run "$lyric_bin" prove --json "$tc/welltyped.l")"
[ "$rc" -eq 0 ] || fail "well-typed file, --json: expected exit 0"
grep -q '"outcome": "discharged"' "$out" || fail "well-typed file, --json: expected a discharged goal"
echo "PASS: well-typed file, --json"

# A package the type checker rejects in another file: neither a single-file
# proof of its sound file nor the --manifest proof goes ahead.
expect_type_error "ill-typed sibling, single file" T0031 "$lyric_bin" prove "$tc/project/src/p/b_logic.l"
expect_type_error "ill-typed sibling, --manifest" T0031 "$lyric_bin" prove --manifest "$tc/project/lyric.toml"
grep -q "a_types.l: error\[T0031\]" "$err" || fail "ill-typed sibling, --manifest: expected the diagnostic attributed to a_types.l"
expect_proved "well-typed package, single file" "$lyric_bin" prove "$tc/control/src/p/b_logic.l"
expect_proved "well-typed package, --manifest" "$lyric_bin" prove --manifest "$tc/control/lyric.toml"

# The check is the build's for the flags given: a package gated to the JVM
# or to a non-default feature does not type-check in a default build, and
# does with --target jvm / --features extra.
expect_type_error "JVM-only package, dotnet, --manifest" T0020 "$lyric_bin" prove --manifest "$tc/jvmonly/lyric.toml"
expect_type_error "JVM-only package, dotnet, single file" T0020 "$lyric_bin" prove "$tc/jvmonly/src/p/b_logic.l"
expect_proved "JVM-only package, --target jvm, --manifest" "$lyric_bin" prove --target jvm --manifest "$tc/jvmonly/lyric.toml"
expect_proved "JVM-only package, --target jvm, single file" "$lyric_bin" prove --target jvm "$tc/jvmonly/src/p/b_logic.l"
expect_type_error "feature-gated package, default features" T0020 "$lyric_bin" prove "$tc/featured/src/p/b_logic.l"
expect_proved "feature-gated package, --features extra" "$lyric_bin" prove --features extra "$tc/featured/src/p/b_logic.l"

# A dependency that is not built stops the proof, as it stops a build.
rc="$(run "$lyric_bin" prove "$tc/unbuiltdep/app/src/app.l")"
[ "$rc" -ne 0 ] || fail "unbuilt dependency: expected a non-zero exit"
grep -q 'run `lyric restore` or `lyric build` first' "$err" || fail "unbuilt dependency: expected the restore/build advice"
grep -q "no proof obligation was attempted" "$err" || fail "unbuilt dependency: expected the refusal"
if grep -q "^build:" "$err" || grep -q "obligations discharged" "$out"; then
  fail "unbuilt dependency: no build-prefixed message and no obligation may be attempted"
fi
echo "PASS: unbuilt dependency"

# A file is checked with its own package and the packages it imports, not
# the whole project: the ledger's accounting package imports only Std, so
# the command its header documents proves it without the service packages'
# dependencies being built.
expect_proved "ledger accounting package" "$lyric_bin" prove "$examples/ledger/src/accounting.l" --verbose

# #8223: a quantifier's side conditions hold for every bound value, whether
# its body is written bare or in braces (#8305).
rc="$(run "$lyric_bin" prove "$qs/unsound.l")"
[ "$rc" -ne 0 ] || fail "quantifier side conditions: expected the unsound postconditions refuted"
for fn in callsEveryByte dividesByEveryByte callsEveryByteBraced dividesByEveryByteBraced; do
  grep -Eq "V0008 error .*postcondition of $fn([^A-Za-z0-9_]|\$)" "$err" || fail "quantifier side conditions: expected $fn refuted"
done
echo "PASS: quantifier side conditions, refuted"
expect_proved "quantifier side conditions, guarded" "$lyric_bin" prove "$qs/sound.l"

# A precondition no argument meets is reported, and the check is not counted
# among the function's obligations.
rc="$(run "$lyric_bin" prove "$qs/vacuous.l")"
[ "$rc" -ne 0 ] || fail "unmeetable precondition: expected a non-zero exit"
grep -q "V0035 error .*precondition of pick can never hold" "$err" || fail "unmeetable precondition: expected V0035"
grep -q "^1/1 obligations discharged" "$out" || fail "unmeetable precondition: expected the vacuity check left out of the count"
echo "PASS: unmeetable precondition"

# #8307: the --json summary counts each outcome of the goals it lists.
summary_field() {
  sed -n '/"summary"/,/}/p' "$out" | sed -n "s/.*\"$1\": \([0-9]*\).*/\1/p"
}
outcome_count() {
  grep -c "\"outcome\": \"$1\"" "$out" || true
}
rc="$(run "$lyric_bin" prove --json "$js/counts.l")"
[ "$rc" -eq 1 ] || fail "--json summary: expected exit 1 for the refuted goal"
for pair in total: discharged:discharged unknown:unknown counterexamples:counterexample; do
  field="${pair%%:*}"
  outcome="${pair#*:}"
  value="$(summary_field "$field")"
  [ -n "$value" ] || fail "--json summary: missing $field"
  if [ -n "$outcome" ]; then
    [ "$value" -eq "$(outcome_count "$outcome")" ] || fail "--json summary: $field disagrees with the goals"
    [ "$value" -ge 1 ] || fail "--json summary: expected at least one $outcome goal"
  else
    [ "$value" -eq "$(grep -c '"outcome": ' "$out")" ] || fail "--json summary: total disagrees with the goals"
  fi
done
[ "$(summary_field total)" -eq $(($(summary_field discharged) + $(summary_field unknown) + $(summary_field counterexamples))) ] ||
  fail "--json summary: total is not the sum of the outcome counts"
echo "PASS: --json summary counts"

# #8309: --proof-dir writes one SMT-LIB query per obligation, named by goal
# index, and --json points each goal at its file.
rc="$(run "$lyric_bin" prove --json --proof-dir "$proofs/q" "$js/counts.l")"
[ "$rc" -eq 1 ] || fail "--proof-dir --json: expected exit 1 for the refuted goal"
total="$(summary_field total)"
[ "$(find "$proofs/q" -name '*.smt2' | wc -l)" -eq "$total" ] || fail "--proof-dir: expected one query per obligation"
[ "$(grep -c '"smtPath": "' "$out")" -eq "$total" ] || fail "--proof-dir --json: expected every goal's smtPath"
grep -q '"smtPath": ".*/q/0-[^"]*\.smt2"' "$out" || fail "--proof-dir --json: expected goal 0's file"
for f in "$proofs"/q/*.smt2; do
  grep -q '(check-sat)' "$f" || fail "--proof-dir: $f is not an SMT-LIB query"
done
rc="$(run "$lyric_bin" prove --proof-dir "$proofs/h" "$tc/welltyped.l")"
[ "$rc" -eq 0 ] || fail "--proof-dir: expected the proof to go through"
grep -q "SMT-LIB queries for 1 obligation(s) written to $proofs/h" "$out" || fail "--proof-dir: expected the report"
[ "$(find "$proofs/h" -name '0-*.smt2' | wc -l)" -eq 1 ] || fail "--proof-dir: expected goal 0's query"
echo "PASS: --proof-dir"

# #8309: an option prove does not take, a second source file, or a misused
# --proof-dir stops before anything is proved.
expect_usage_error() {
  local label="$1" message="$2"; shift 2
  local rc
  rc="$(run "$@")"
  [ "$rc" -ne 0 ] || fail "$label: expected a non-zero exit"
  grep -qF "$message" "$err" || fail "$label: expected '$message'"
  if grep -q "obligations discharged" "$out"; then
    fail "$label: nothing may be proved"
  fi
  echo "PASS: $label"
}
expect_usage_error "unknown option" "prove: unknown option '--proof-dirs'" \
  "$lyric_bin" prove --proof-dirs "$proofs/x" "$tc/welltyped.l"
expect_usage_error "unknown short option" "prove: unknown option '-q'" "$lyric_bin" prove -q "$tc/welltyped.l"
expect_usage_error "unknown option after the source" "prove: unknown option '--jsn'" \
  "$lyric_bin" prove "$tc/welltyped.l" --jsn
expect_usage_error "two source files" "prove: expected one source file, got 2" \
  "$lyric_bin" prove "$tc/welltyped.l" "$qs/sound.l"
expect_usage_error "--proof-dir without a directory" "prove: --proof-dir requires a directory" \
  "$lyric_bin" prove "$tc/welltyped.l" --proof-dir
expect_usage_error "--proof-dir in project mode" "prove: --proof-dir requires a source file" \
  "$lyric_bin" prove --proof-dir "$proofs/p" --manifest "$tc/control/lyric.toml"
[ ! -e "$proofs/x" ] && [ ! -e "$proofs/p" ] || fail "a refused run may not write a proof directory"
echo "PASS: refused runs write nothing"
