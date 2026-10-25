#!/usr/bin/env bash
# `lyric prove` type-checks the program before it proves anything (#8227): a
# file or project the type checker rejects stops with the type checker's
# diagnostics and a non-zero exit, in the single-file, --manifest and --json
# modes, while its type-correct twin is proved.  Also: a quantifier's body
# keeps its side conditions (#8223) — a goal the verifier used to prove
# because it dropped them is refuted, and its guarded twin is proved.  And
# the --json summary counts every outcome (#8307), --proof-dir writes the
# obligations' SMT-LIB queries, and an option prove does not take is an
# error rather than a source path (#8309).  A quantifier body or guard that
# is not Bool (#8322) and an ill-typed test body (#8308) are type errors,
# and --verbose prints each goal's query and solver response (#8320).
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

# #8322: a quantifier's body is a proposition.
expect_type_error "non-Bool quantifier body" T0132 "$lyric_bin" prove "$tc/nonbool_quantifier.l"
grep -q "a forall body must be Bool (got Byte)" "$err" || fail "non-Bool quantifier body: expected the message"
expect_type_error "non-Bool quantified invariant conjunct" T0132 "$lyric_bin" prove "$tc/nonbool_invariant.l"
grep -q "nonbool_invariant.l: error\[T0132\] 9:" "$err" || fail "non-Bool quantified invariant conjunct: expected it at the invariant"
# #8308: a test body is type-checked by the checker itself, not only after
# `lyric test` rewrites it.
expect_type_error "ill-typed test body" T0043 "$lyric_bin" prove "$tc/illtyped_test.l"
grep -q "illtyped_test.l: error\[T0043\] 13:" "$err" || fail "ill-typed test body: expected the error at the test body's line"

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

# #8311: the check runs the passes the target's own build runs.  The native
# bridge synthesises no `@stubbable` stubs (docs/59 §9.2), so `lyric build
# --target native` rejects a program that uses one with T0020, and so does
# `lyric prove --target native`; dotnet and the JVM synthesise it.
expect_proved "stubbable use, dotnet" "$lyric_bin" prove "$tc/stubbable.l"
expect_proved "stubbable use, --target jvm" "$lyric_bin" prove --target jvm "$tc/stubbable.l"
expect_type_error "stubbable use, --target native" T0020 "$lyric_bin" prove --target native "$tc/stubbable.l"
grep -q "unknown name 'SourceStub'" "$err" || fail "stubbable use, --target native: expected the build's own message"
rc="$(run "$lyric_bin" build --target native "$tc/stubbable.l" -o "$proofs/stubbable-native")"
[ "$rc" -ne 0 ] || fail "stubbable use: expected the native build to reject it too"
grep -q "unknown name 'SourceStub'" "$err" || fail "stubbable use: expected the native build's message to be the check's"
echo "PASS: stubbable use, the native build agrees"

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
# One run serves both this and the --proof-dir checks below: the undecided
# goal costs the solver's whole time limit.
rc="$(run "$lyric_bin" prove --json --proof-dir "$proofs/q" "$js/counts.l")"
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
total="$(summary_field total)"
[ "$(find "$proofs/q" -name '*.smt2' | wc -l)" -eq "$total" ] || fail "--proof-dir: expected one query per obligation"
[ "$(grep -c '"smtPath": "' "$out")" -eq "$total" ] || fail "--proof-dir --json: expected every goal's smtPath"
grep -q '"smtPath": ".*/q/0-[^"]*\.smt2"' "$out" || fail "--proof-dir --json: expected goal 0's file"
for f in "$proofs"/q/*.smt2; do
  grep -q '(check-sat)' "$f" || fail "--proof-dir: $f is not an SMT-LIB query"
done
# A re-run leaves only its own queries: an earlier run's .smt2 files go,
# other files stay.
mkdir -p "$proofs/h"
echo stale > "$proofs/h/7-gone_post.smt2"
echo keep > "$proofs/h/notes.txt"
rc="$(run "$lyric_bin" prove --proof-dir "$proofs/h" "$tc/welltyped.l")"
[ "$rc" -eq 0 ] || fail "--proof-dir: expected the proof to go through"
grep -q "SMT-LIB queries for 1 obligation(s) written to $proofs/h" "$out" || fail "--proof-dir: expected the report"
[ "$(find "$proofs/h" -name '0-*.smt2' | wc -l)" -eq 1 ] || fail "--proof-dir: expected goal 0's query"
[ ! -e "$proofs/h/7-gone_post.smt2" ] || fail "--proof-dir: an earlier run's query survived"
[ -f "$proofs/h/notes.txt" ] || fail "--proof-dir: a file that is not a query was removed"
# --explain writes the queries only once its goal index is known good.
rc="$(run "$lyric_bin" prove --explain --goal 0 --proof-dir "$proofs/e" "$tc/welltyped.l")"
[ "$rc" -eq 0 ] || fail "--proof-dir --explain: expected exit 0"
[ "$(find "$proofs/e" -name '*.smt2' | wc -l)" -eq 1 ] || fail "--proof-dir --explain: expected the query"
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
expect_usage_error "--proof-dir followed by an option" "prove: --proof-dir requires a directory" \
  "$lyric_bin" prove --proof-dir --json "$tc/welltyped.l"
expect_usage_error "--explain goal out of range" "prove --explain: goal 5 out of range" \
  "$lyric_bin" prove --explain --goal 5 --proof-dir "$proofs/g" "$tc/welltyped.l"
expect_usage_error "--proof-dir in project mode" "prove: --proof-dir requires a source file" \
  "$lyric_bin" prove --proof-dir "$proofs/p" --manifest "$tc/control/lyric.toml"
[ ! -e "$proofs/x" ] && [ ! -e "$proofs/p" ] && [ ! -e "$proofs/g" ] && [ ! -e ./--json ] || fail "a refused run may not write a proof directory"
echo "PASS: refused runs write nothing"

# #8320: --verbose prints, for each obligation, its result line, its SMT-LIB
# query and the solver's raw response, before the summary line.
rc="$(run "$lyric_bin" prove --verbose "$tc/welltyped.l")"
[ "$rc" -eq 0 ] || fail "--verbose: expected the proof to go through"
grep -Eq "^goal 0: .*: discharged \[(z3|cvc5|trivial discharger)\]$" "$out" || fail "--verbose: expected goal 0's result line"
grep -q "^  ;; SMT-LIB query$" "$out" || fail "--verbose: expected the query heading"
grep -q "^  (check-sat)$" "$out" || fail "--verbose: expected the query"
grep -Eq "^  ;; ((z3|cvc5) response|no solver run: the trivial discharger decided the obligation)$" "$out" ||
  fail "--verbose: expected the solver's response heading"
[ "$(tail -n 1 "$out")" = "1/1 obligations discharged (@proof_required)" ] || fail "--verbose: expected the summary line last"
echo "PASS: --verbose"
# A refuted goal shows the solver's own answer: sat and its model.
rc="$(run "$lyric_bin" prove --verbose "$qs/unsound.l")"
[ "$rc" -ne 0 ] || fail "--verbose, refuted: expected a non-zero exit"
grep -Eq "^goal [0-9]+: .*: counterexample \[(z3|cvc5)\]$" "$out" || fail "--verbose, refuted: expected a counterexample line"
grep -Eq "^  ;; (z3|cvc5) response$" "$out" || fail "--verbose, refuted: expected the solver's response"
grep -q "^  sat$" "$out" || fail "--verbose, refuted: expected the solver's sat"
echo "PASS: --verbose, refuted"
rc="$(run "$lyric_bin" prove --verbose --explain --goal 0 "$tc/welltyped.l")"
[ "$rc" -eq 0 ] || fail "--verbose --explain: expected exit 0"
[ "$(grep -c "^goal " "$out")" -eq 1 ] || fail "--verbose --explain: expected the one goal's result line"
grep -q "^  (check-sat)$" "$out" || fail "--verbose --explain: expected the goal's query"
echo "PASS: --verbose --explain"
rc="$(run "$lyric_bin" prove -v --manifest "$tc/control/lyric.toml")"
[ "$rc" -eq 0 ] || fail "--verbose, project mode: expected exit 0"
grep -q "^goal 0: " "$out" || fail "--verbose, project mode: expected the goals' result lines"
grep -q "^.*b_logic\.l:$" "$out" || fail "--verbose, project mode: expected each file's header"
echo "PASS: --verbose, project mode"
expect_usage_error "--verbose with --json" "prove: --verbose cannot be combined with --json" \
  "$lyric_bin" prove --verbose --json "$tc/welltyped.l"
if grep -q '"goals"' "$out"; then
  fail "--verbose with --json: no document may be written"
fi
# The precondition checks behind V0035/V0036 are shown too, unnumbered.
rc="$(run "$lyric_bin" prove --verbose "$qs/vacuous.l")"
[ "$rc" -ne 0 ] || fail "--verbose, precondition checks: expected the V0035 exit"
grep -Eq "^precondition check: .*: can never hold \(V0035\) \[[^]]+\]$" "$out" ||
  fail "--verbose, precondition checks: expected the unmeetable clause's check"
echo "PASS: --verbose, precondition checks"
# The solver is named by its kind, not by its binary's file name.
if command -v z3 > /dev/null; then
  mkdir -p "$proofs/bin"
  ln -sf "$(command -v z3)" "$proofs/bin/z3-renamed"
  rc="$(LYRIC_Z3="$proofs/bin/z3-renamed" run "$lyric_bin" prove --verbose "$qs/unsound.l")"
  grep -Eq "^goal [0-9]+: .*: counterexample \[z3\]$" "$out" || fail "--verbose, renamed z3: expected the solver named z3"
  echo "PASS: --verbose, renamed z3"
fi
rc="$(run "$lyric_bin" prove --help)"
[ "$rc" -eq 0 ] || fail "--help: expected exit 0"
for opt in --verbose --json --explain --goal --proof-dir; do
  grep -q -- "$opt" "$out" || fail "--help: expected $opt"
done
echo "PASS: prove --help"
