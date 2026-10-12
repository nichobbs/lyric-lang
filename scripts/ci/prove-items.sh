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
#   * record and `impl` methods are verified like functions (#8231).
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
