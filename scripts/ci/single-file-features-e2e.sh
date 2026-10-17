#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# single-file-features-e2e.sh — how a single source file's build
# configuration is chosen (D182, #8339), end to end through the CLI.
#
#   LYRIC_BIN=<lyric> bash scripts/ci/single-file-features-e2e.sh
#
#   * `--features` on a file no manifest applies to is F0049 from every
#     command that takes it (`build`, `run`, `test`, `prove`), with no
#     output written; the same file without `--features` (and with
#     `--no-default-features` / `--all-features`, which select nothing
#     either way) still builds and runs, and `--features` after `--` is the
#     program's argument.
#   * A file under a manifest that does not list it is compiled and proved
#     with that manifest's features: `lyric build`/`run` and `lyric prove`
#     erase the same `@cfg` items, by default and under
#     `--no-default-features`, `--features`, `--target jvm` and `--manifest`.
#
# Needs dotnet, Java 21 and z3.  Invoked from `compiler-self-tests-batch.sh`.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_CONFIG="${BUILD_CONFIG:-Debug}"
lyric_bin="${LYRIC_BIN:-$REPO_ROOT/bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric}"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin" >&2
  exit 1
fi
lyric_bin="$(cd "$(dirname "$lyric_bin")" && pwd)/$(basename "$lyric_bin")"

# Outside the repository, so a manifest-less file discovers no manifest.
work="$(mktemp -d)"
out="$work/stdout"
err="$work/stderr"
trap 'rm -rf "${work:?}"' EXIT

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

# ── Fixtures ────────────────────────────────────────────────────────────────
mkdir -p "$work/loose" "$work/proj/src/p" "$work/proj/tools"

# The issue's repro: one `h` per setting of the feature `a`.
cat > "$work/loose/dup.l" <<'EOF'
package Dup

@cfg(feature = "a")
func h(): Int {
  1
}

@cfg(not(feature = "a"))
func h(): Int {
  2
}

func main(): Unit {
  println(toString(h()))
}
EOF

cat > "$work/loose/dup_tests.l" <<'EOF'
@test_module
package DupTests

import Std.Testing

test "two" {
  assertEqualInt(1 + 1, 2, "two")
}
EOF

cat > "$work/proj/lyric.toml" <<'TOML'
[package]
name = "FeatureScripts"
version = "0.1.0"

[project]
name = "FeatureScripts"
output = "single"
output_assembly = "FeatureScripts.dll"

[project.packages]
"P" = "src/p"

[features]
default = ["wide"]
wide = []
TOML

cat > "$work/proj/src/p/p.l" <<'EOF'
package P

pub func one(): Int {
  1
}
EOF

# Not listed by the manifest above it.  `limit` has one declaration per
# setting of `wide`; `atLeastHundred` holds only with the wide one.
cat > "$work/proj/tools/limits.l" <<'EOF'
@proof_required
package Limits

@cfg(feature = "wide")
pub func limit(): Int
  ensures: result == 1000
{
  1000
}

@cfg(not(feature = "wide"))
pub func limit(): Int
  ensures: result == 10
{
  10
}

pub func atLeastHundred(): Int
  ensures: result >= 100
{
  limit()
}
EOF

# Not listed either: it type-checks only when `wide` is active.
cat > "$work/proj/tools/gated.l" <<'EOF'
package Gated

@cfg(feature = "wide")
pub func wideLimit(): Int {
  1000
}

pub func useIt(): Int {
  wideLimit()
}
EOF

# Not listed either: prints the `limit` the build compiled.
cat > "$work/proj/tools/show.l" <<'EOF'
package Show

@cfg(feature = "wide")
func limit(): Int {
  1000
}

@cfg(not(feature = "wide"))
func limit(): Int {
  10
}

func main(): Unit {
  println(toString(limit()))
}
EOF

# ── 1. `--features` with no manifest is F0049 ───────────────────────────────
expect_f0049() {
  local label="$1"; shift
  local rc
  rc="$(run "$@")"
  [ "$rc" -ne 0 ] || fail "$label: expected a non-zero exit"
  grep -q "^error\[F0049\]: --features a selects features a manifest's \[features\] table declares, but .*dup.*\.l has no manifest" "$err" ||
    fail "$label: expected F0049"
  if grep -q "Unhandled exception" "$out" "$err"; then
    fail "$label: crashed"
  fi
  echo "PASS: $label"
}

cd "$work/loose"
expect_f0049 "build --features, no manifest" "$lyric_bin" build dup.l --features a
[ ! -e dup.dll ] || fail "build --features, no manifest: no output may be written"
expect_f0049 "build --features --target jvm, no manifest" "$lyric_bin" build dup.l --target jvm --features a
[ ! -e dup.jar ] || fail "build --features --target jvm, no manifest: no output may be written"
expect_f0049 "run --features, no manifest" "$lyric_bin" run dup.l --features a
expect_f0049 "run --watch --features, no manifest" "$lyric_bin" run --watch dup.l --features a
expect_f0049 "prove --features, no manifest" "$lyric_bin" prove dup.l --features a
expect_f0049 "test --features, no manifest" "$lyric_bin" test dup_tests.l --features a

rc="$(run "$lyric_bin" build dup.l)"
[ "$rc" -eq 0 ] || fail "build, no manifest: expected success"
[ -e dup.dll ] || fail "build, no manifest: expected dup.dll"
echo "PASS: build, no manifest"
for flag in "" --no-default-features --all-features; do
  # shellcheck disable=SC2086
  rc="$(run "$lyric_bin" run dup.l $flag)"
  [ "$rc" -eq 0 ] || fail "run ${flag:-(no flag)}, no manifest: expected success"
  [ "$(tail -n1 "$out")" = "2" ] || fail "run ${flag:-(no flag)}, no manifest: expected the not(a) twin"
  echo "PASS: run ${flag:-(no flag)}, no manifest"
done
rc="$(run "$lyric_bin" run dup.l -- --features a)"
[ "$rc" -eq 0 ] || fail "run -- --features a: the program's arguments are not the command's"
[ "$(tail -n1 "$out")" = "2" ] || fail "run -- --features a: expected the not(a) twin"
echo "PASS: run -- --features a passes the flag to the program"
rc="$(run "$lyric_bin" test dup_tests.l)"
[ "$rc" -eq 0 ] || fail "test, no manifest: expected success"
echo "PASS: test, no manifest"

# ── 2. An unlisted file under a manifest: build and prove agree ─────────────
cd "$work"
m="$work/proj/lyric.toml"

expect_proved() {
  local label="$1"; shift
  local rc
  rc="$(run "$@")"
  [ "$rc" -eq 0 ] || fail "$label: expected the proof to go through"
  grep -q "^2/2 obligations discharged" "$out" ||
    fail "$label: expected both obligations of the wide twin discharged"
  echo "PASS: $label"
}

expect_refuted() {
  local label="$1"; shift
  local rc
  rc="$(run "$@")"
  [ "$rc" -ne 0 ] || fail "$label: expected a non-zero exit"
  grep -Eq "V0008 error .*postcondition of atLeastHundred" "$err" || fail "$label: expected atLeastHundred refuted"
  echo "PASS: $label"
}

expect_proved "prove unlisted file, manifest default features" "$lyric_bin" prove proj/tools/limits.l
grep -q "inactive @cfg variant(s) not proved; the declaration of the same name this build compiles is: limit$" "$out" ||
  fail "prove unlisted file: expected the narrow twin listed as inactive"
expect_proved "prove unlisted file, --target jvm" "$lyric_bin" prove --target jvm proj/tools/limits.l
expect_proved "prove unlisted file, --features wide" "$lyric_bin" prove --no-default-features --features wide proj/tools/limits.l
expect_proved "prove unlisted file, --manifest" "$lyric_bin" prove --manifest "$m" proj/tools/limits.l
expect_refuted "prove unlisted file, --no-default-features" "$lyric_bin" prove --no-default-features proj/tools/limits.l
expect_refuted "prove unlisted file, --manifest --no-default-features" \
  "$lyric_bin" prove --manifest "$m" --no-default-features proj/tools/limits.l

for target in dotnet jvm; do
  rc="$(run "$lyric_bin" run --target "$target" proj/tools/show.l)"
  [ "$rc" -eq 0 ] || fail "run unlisted file ($target): expected success"
  [ "$(tail -n1 "$out")" = "1000" ] || fail "run unlisted file ($target): expected the wide twin"
  echo "PASS: run unlisted file ($target), manifest default features"
  rc="$(run "$lyric_bin" run --target "$target" proj/tools/show.l --no-default-features)"
  [ "$rc" -eq 0 ] || fail "run unlisted file ($target) --no-default-features: expected success"
  [ "$(tail -n1 "$out")" = "10" ] || fail "run unlisted file ($target) --no-default-features: expected the narrow twin"
  echo "PASS: run unlisted file ($target), --no-default-features"
done

# The type check: build and prove accept the file under the same features
# and reject it, with the same diagnostic, under the same features.
rc="$(run "$lyric_bin" build proj/tools/gated.l -o "$work/gated.dll")"
[ "$rc" -eq 0 ] || fail "build gated unlisted file: expected success under the default features"
echo "PASS: build gated unlisted file, default features"
rc="$(run "$lyric_bin" prove proj/tools/gated.l)"
[ "$rc" -eq 0 ] || fail "prove gated unlisted file: expected it to pass the build's type check"
grep -q "no proof obligations" "$out" || fail "prove gated unlisted file: expected it checked and proved"
echo "PASS: prove gated unlisted file, default features"
rc="$(run "$lyric_bin" build proj/tools/gated.l --no-default-features -o "$work/gated.dll")"
[ "$rc" -ne 0 ] || fail "build gated unlisted file --no-default-features: expected a type error"
build_codes="$(grep -oE "error\[T[0-9]+\]|T[0-9]{4} error|error T[0-9]{4}" "$err" | grep -oE "T[0-9]{4}" | sort -u | tr '\n' ' ')"
[ -n "$build_codes" ] || fail "build gated unlisted file --no-default-features: expected a T-coded diagnostic"
rc="$(run "$lyric_bin" prove proj/tools/gated.l --no-default-features)"
[ "$rc" -ne 0 ] || fail "prove gated unlisted file --no-default-features: expected the build's type error"
grep -q "fails the build's checks; no proof obligation was attempted" "$err" ||
  fail "prove gated unlisted file --no-default-features: expected the refusal"
prove_codes="$(grep -oE "error\[T[0-9]+\]|T[0-9]{4} error|error T[0-9]{4}" "$err" | grep -oE "T[0-9]{4}" | sort -u | tr '\n' ' ')"
[ "$build_codes" = "$prove_codes" ] ||
  fail "gated unlisted file --no-default-features: build reported [$build_codes], prove [$prove_codes]"
echo "PASS: build and prove reject the gated unlisted file alike ($build_codes)"

echo "single-file features e2e passed"
