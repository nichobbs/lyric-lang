#!/usr/bin/env bash
# `lyric prove` proves exactly what the build compiles, and every body it
# compiles:
#   * two `@cfg`-gated declarations of one name are proved as the build
#     erases them for its `--target`/`--features`, in single-file and
#     --manifest mode, instead of crashing on the duplicate (#8325);
#   * a goal that depends on a `match` arm the verifier does not model — a
#     union declared in another file, a constructor pattern — is reported
#     (V0027 error) and not proved, while a match no goal needs is not an
#     error (#8230);
#   * record and `impl` methods are verified like functions, an `impl`
#     method against the clauses of the interface it implements — resolved
#     as the type checker resolves it, the standard library's included —
#     and a bare `Some`/`None`/`Ok`/`Err` pattern is a case (#8231, #8230);
#   * the `@proof_required` items no build compiles are listed (#8325).
#
#   LYRIC_BIN=<lyric> bash scripts/ci/prove-items.sh
set -euo pipefail
lyric_bin="${LYRIC_BIN:?LYRIC_BIN must name the lyric binary}"
lyric_bin="$(cd "$(dirname "$lyric_bin")" && pwd)/$(basename "$lyric_bin")"
examples="$(cd "$(dirname "$0")/../.." && pwd)/examples"
cfg="$examples/prove-cfg"
um="$examples/prove-unmodelled-match"
pm="$examples/prove-methods"
out="$(mktemp)"
err="$(mktemp)"
trap 'rm -f "$out" "$err"' EXIT

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

no_crash() {
  if grep -q "Unhandled exception" "$err" "$out"; then
    fail "$1: the prover crashed"
  fi
}

expect_proved() {
  local label="$1"; shift
  local rc
  rc="$(run "$@")"
  no_crash "$label"
  [ "$rc" -eq 0 ] || fail "$label: expected the proof to go through"
  grep -Eq "([0-9]+)/\1 obligations discharged" "$out" || fail "$label: expected every obligation discharged"
  echo "PASS: $label"
}

# A refutation of `fn` (V0008): the proof ran, and found the goal false.
expect_refuted() {
  local label="$1" fn="$2"; shift 2
  local rc
  rc="$(run "$@")"
  no_crash "$label"
  [ "$rc" -ne 0 ] || fail "$label: expected a non-zero exit"
  grep -Eq "V0008 error .*$fn" "$err" || fail "$label: expected $fn refuted"
  echo "PASS: $label"
}

# #8325: the proof is of the build's items.
expect_proved "target twins, dotnet" "$lyric_bin" prove "$cfg/twins.l"
expect_proved "target twins, --target jvm" "$lyric_bin" prove --target jvm "$cfg/twins.l"
rc="$(run "$lyric_bin" prove "$cfg/twins.l")"
grep -q "^2/2 obligations discharged" "$out" || fail "target twins: expected one twin's goals, not both"
expect_refuted "feature twins, default features" "postcondition of atLeastHundred" \
  "$lyric_bin" prove "$cfg/project/src/p/limits.l"
grep -q "^1 inactive @cfg variant(s) not proved; the declaration of the same name this build compiles is: limit$" "$out" ||
  fail "feature twins, default features: expected the inactive twin listed"
echo "PASS: feature twins, inactive twin listed"
expect_proved "a JVM-only item, dotnet" "$lyric_bin" prove "$cfg/jvm_only.l"
grep -q "^1 item(s) not proved: inactive under this build (@cfg): onJvm$" "$out" ||
  fail "a JVM-only item, dotnet: expected it listed as not proved"
echo "PASS: a JVM-only item listed"
rc="$(run "$lyric_bin" prove --target jvm "$cfg/jvm_only.l")"
if grep -q "not proved: inactive" "$out"; then
  fail "a JVM-only item, --target jvm: nothing is inactive"
fi
echo "PASS: a JVM-only item proved on the JVM"
expect_proved "feature twins, --features wide" "$lyric_bin" prove --features wide "$cfg/project/src/p/limits.l"
expect_refuted "feature twins, --manifest" "postcondition of atLeastHundred" \
  "$lyric_bin" prove --manifest "$cfg/project/lyric.toml"
expect_proved "feature twins, --manifest --features wide" \
  "$lyric_bin" prove --features wide --manifest "$cfg/project/lyric.toml"

# #8230: a postcondition on an unmodelled match fails closed; the match no
# goal needs does not.
for mode in single manifest; do
  if [ "$mode" = single ]; then
    rc="$(run "$lyric_bin" prove "$um/project/src/p/b_logic.l")"
  else
    rc="$(run "$lyric_bin" prove --manifest "$um/project/lyric.toml")"
  fi
  no_crash "unmodelled match, $mode"
  [ "$rc" -ne 0 ] || fail "unmodelled match, $mode: expected a non-zero exit"
  grep -Eq "V0027 error .*postcondition of f depends on the value of a match" "$err" ||
    fail "unmodelled match, $mode: expected V0027 at f's postcondition"
  if grep -Eq "V0027 error .*label" "$err"; then
    fail "unmodelled match, $mode: label's goals do not depend on its match"
  fi
  grep -q "1/2 obligations discharged" "$out" || fail "unmodelled match, $mode: expected f's postcondition not discharged"
  echo "PASS: unmodelled match, $mode"
done

# #8231: methods are verified.
expect_refuted "impl method assertion" "user assertion" "$lyric_bin" prove "$pm/impl_method.l"
rc="$(run "$lyric_bin" prove --explain "$pm/impl_method.l")"
grep -q "Pen.pig\$post" "$err" || fail "impl method: expected Pen.pig's goals listed"
echo "PASS: impl method goals listed"
expect_proved "record and impl methods that hold" "$lyric_bin" prove "$pm/methods_hold.l"
grep -q "^2/2 obligations discharged" "$out" || fail "record and impl methods that hold: expected both methods' goals"
echo "PASS: record and impl methods proved"

# A V0027 at a goal, not a refutation: the goal depends on what the verifier
# does not model.
expect_unmodelled() {
  local label="$1" fn="$2"; shift 2
  local rc
  rc="$(run "$@")"
  no_crash "$label"
  [ "$rc" -ne 0 ] || fail "$label: expected a non-zero exit"
  grep -Eq "V0027 error .*of $fn " "$err" || fail "$label: expected V0027 at $fn's goal"
  if grep -q "V0008" "$err"; then
    fail "$label: expected no counterexample"
  fi
  echo "PASS: $label"
}
expect_unmodelled "bare Err pattern" "g" "$lyric_bin" prove "$um/bare_err.l"
expect_unmodelled "@pure callee with an unmodelled match" "a" "$lyric_bin" prove "$um/pure_callee.l"
expect_proved "standard-library interface clauses inherited" "$lyric_bin" prove "$pm/stdlib_interface/reader.l"
expect_refuted "another package's same-named interface is not inherited" "postcondition of F.read" \
  "$lyric_bin" prove "$pm/foreign_sibling/proved.l"
if grep -q "V0033" "$err"; then
  fail "another package's same-named interface: Std.Stream's resolves"
fi
expect_refuted "a bare call in an inherited clause" "postcondition of R.get" "$lyric_bin" prove "$pm/inherited_bare_call.l"

# A union of a dependency restored as a compiled assembly is not resolved to
# a same-named union of a package the verifier read (Std.Http's HttpError):
# its bare cases are not modelled.  Built in a copy, so the example tree
# stays clean.
restored="$(mktemp -d)"
trap 'rm -f "$out" "$err"; rm -rf "${restored:?}"' EXIT
cp -r "$um/restored/." "$restored/"
rc="$(run "$lyric_bin" build --manifest "$restored/lib/lyric.toml")"
[ "$rc" -eq 0 ] || fail "restored dependency: the library did not build"
rc="$(run "$lyric_bin" restore --manifest "$restored/app/lyric.toml")"
[ "$rc" -eq 0 ] || fail "restored dependency: the app's dependencies did not restore"
expect_unmodelled "a restored dependency's union" "f" "$lyric_bin" prove "$restored/app/src/app.l"
