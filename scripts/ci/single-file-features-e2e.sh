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
#     `--watch` and `--aot` reject it up front too, and a relative path with
#     `..` finds the manifest above the file, not above the working
#     directory.
#   * A file under a manifest that does not list it is compiled, checked,
#     tested and proved with that manifest's features: `lyric build`/`run`/
#     `check`/`test` and `lyric prove` erase the same `@cfg` items, by
#     default and under `--no-default-features`, `--features`, `--target
#     jvm` and `--manifest`.
#   * An explicit `--manifest` that is missing or broken is a hard error for
#     `lyric prove` as for `lyric build`; nothing is proved.
#   * A file in a listing project's package directory whose nearest manifest
#     is a nested `[package]` one is proved under that manifest's build too,
#     the one `lyric build <file>` uses: a postcondition only the listing
#     project's features make true is refuted, never falsely proved.
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

# Not listed either: a test module whose assertion holds only with `wide`.
cat > "$work/proj/tools/feat_tests.l" <<'EOF'
@test_module
package FeatTests

import Std.Testing

@cfg(feature = "wide")
func limit(): Int {
  1000
}

@cfg(not(feature = "wide"))
func limit(): Int {
  10
}

test "the wide limit" {
  assertEqualInt(limit(), 1000, "limit")
}
EOF

# A project whose `src` package directory holds a nested `[package]`
# manifest with no default features: `nest/src/tool/limits.l` is in the
# outer `App` entry and under the nested manifest at once.
mkdir -p "$work/nest/src/app" "$work/nest/src/tool"
cat > "$work/nest/lyric.toml" <<'TOML'
[package]
name = "Outer"
version = "0.1.0"

[project]
name = "Outer"
output = "single"
output_assembly = "Outer.dll"

[project.packages]
"App" = "src"

[features]
default = ["wide"]
wide = []
TOML
cat > "$work/nest/src/tool/lyric.toml" <<'TOML'
[package]
name = "Tool"
version = "0.1.0"

[features]
default = []
wide = []
TOML
cat > "$work/nest/src/app/app.l" <<'EOF'
package App

pub func one(): Int {
  1
}
EOF
cat > "$work/nest/src/tool/limits.l" <<'EOF'
@proof_required
package App

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

func main(): Unit {
  println(toString(atLeastHundred()))
}
EOF

# A manifest that does not parse, and manifest-less copies of the tools.
mkdir -p "$work/broken"
printf '[package]\nname = \n' > "$work/broken/lyric.toml"
cp "$work/proj/tools/limits.l" "$work/loose/limits.l"
cp "$work/proj/tools/show.l" "$work/loose/show.l"
cp "$work/proj/tools/gated.l" "$work/loose/gated.l"

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
expect_f0049 "build --aot --features, no manifest" "$lyric_bin" build --aot dup.l --features a
[ ! -e dup ] || fail "build --aot --features, no manifest: no output may be written"
# `--watch` rejects it once, up front, instead of reporting it and polling.
rc="$(run timeout 120 "$lyric_bin" build --watch dup.l --features a)"
[ "$rc" -ne 124 ] || fail "build --watch --features, no manifest: kept polling"
[ "$rc" -ne 0 ] || fail "build --watch --features, no manifest: expected a non-zero exit"
grep -q "^error\[F0049\]" "$err" || fail "build --watch --features, no manifest: expected F0049"
if grep -q "watching" "$out"; then
  fail "build --watch --features, no manifest: started watching"
fi
echo "PASS: build --watch --features, no manifest"

# A relative path with `..` walks up from the file, not from the working
# directory: here the cwd is a project with `[features]` and the file has
# no manifest.
cd "$work/proj"
expect_f0049 "run ../loose/dup.l --features, cwd in another project" "$lyric_bin" run ../loose/dup.l --features a
expect_f0049 "prove ../loose/dup.l --features, cwd in another project" "$lyric_bin" prove ../loose/dup.l --features a
expect_f0049 "build ../loose/dup.l --features, cwd in another project" "$lyric_bin" build ../loose/dup.l --features a
rc="$(run "$lyric_bin" run ../loose/show.l)"
[ "$rc" -eq 0 ] || fail "run ../loose/show.l: expected success"
[ "$(tail -n1 "$out")" = "10" ] || fail "run ../loose/show.l: the cwd's project features must not apply"
echo "PASS: run ../loose/show.l takes no manifest's features"
rc="$(run "$lyric_bin" prove ../loose/limits.l)"
[ "$rc" -ne 0 ] || fail "prove ../loose/limits.l: expected the narrow twin to refute atLeastHundred"
grep -Eq "V0008 error .*postcondition of atLeastHundred" "$err" ||
  fail "prove ../loose/limits.l: the cwd's project features must not apply"
echo "PASS: prove ../loose/limits.l takes no manifest's features"
cd "$work/loose"

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

# `lyric check <file>` checks the file as `lyric build <file>` builds it.
rc="$(run "$lyric_bin" check proj/tools/gated.l)"
[ "$rc" -eq 0 ] || fail "check gated unlisted file: expected the manifest's default feature"
echo "PASS: check gated unlisted file, default features"
rc="$(run "$lyric_bin" check loose/gated.l)"
[ "$rc" -ne 0 ] || fail "check gated file with no manifest: expected the type error"
echo "PASS: check gated file with no manifest is rejected"
rc="$(run "$lyric_bin" check --manifest "$m" loose/gated.l)"
[ "$rc" -eq 0 ] || fail "check --manifest gated file: expected the manifest's default feature"
echo "PASS: check --manifest <m> gated file"

# `lyric run --manifest <m> <file>`: the file builds under `m`.
rc="$(run "$lyric_bin" run --manifest "$m" loose/show.l)"
[ "$rc" -eq 0 ] || fail "run --manifest: expected success"
[ "$(tail -n1 "$out")" = "1000" ] || fail "run --manifest: expected the manifest's default feature"
rc="$(run "$lyric_bin" run --manifest "$m" loose/show.l --no-default-features)"
[ "$rc" -eq 0 ] || fail "run --manifest --no-default-features: expected success"
[ "$(tail -n1 "$out")" = "10" ] || fail "run --manifest --no-default-features: expected the narrow twin"
echo "PASS: run --manifest <m> <file>"

# `lyric test <file>` under a manifest that does not list it.
rc="$(run "$lyric_bin" test proj/tools/feat_tests.l)"
[ "$rc" -eq 0 ] || fail "test under a manifest: expected the manifest's default feature"
rc="$(run "$lyric_bin" test proj/tools/feat_tests.l --no-default-features)"
[ "$rc" -ne 0 ] || fail "test --no-default-features under a manifest: expected the narrow twin to fail the test"
rc="$(run "$lyric_bin" test proj/tools/feat_tests.l --no-default-features --features wide)"
[ "$rc" -eq 0 ] || fail "test --features wide under a manifest: expected the wide twin"
echo "PASS: test --features under a manifest"

# ── 3. An explicit `--manifest` that cannot be used is a hard error ─────────
for kind in missing broken; do
  if [ "$kind" = missing ]; then mf="$work/nope/lyric.toml"; else mf="$work/broken/lyric.toml"; fi
  for cmd in prove build; do
    rc="$(run "$lyric_bin" "$cmd" --manifest "$mf" loose/limits.l --features wide)"
    [ "$rc" -ne 0 ] || fail "$cmd --manifest ($kind): expected a hard error"
    grep -q "^$cmd: " "$err" || fail "$cmd --manifest ($kind): expected the manifest error"
    if grep -q "obligations discharged" "$out"; then
      fail "$cmd --manifest ($kind): nothing may be proved"
    fi
    echo "PASS: $cmd --manifest ($kind) is a hard error"
  done
done
rc="$(run "$lyric_bin" prove --manifest "$work/nope/lyric.toml" loose/limits.l)"
[ "$rc" -ne 0 ] || fail "prove --manifest (missing), no --features: expected a hard error"
grep -q "^prove: cannot read manifest $work/nope/lyric.toml" "$err" ||
  fail "prove --manifest (missing): expected 'cannot read manifest'"
echo "PASS: prove --manifest (missing) names the file, with or without --features"

# ── 4. A nested `[package]` manifest inside a listing project ───────────────
# `lyric build nest/src/tool/limits.l` builds it under the nested manifest,
# with no features, where `atLeastHundred` returns 10: the proof covers that
# build and refutes the postcondition, as running the program violates it.
for target in dotnet jvm; do
  rc="$(run "$lyric_bin" prove --target "$target" nest/src/tool/limits.l)"
  [ "$rc" -ne 0 ] || fail "nested manifest ($target): expected the refutation"
  grep -Eq "V0008 error .*postcondition of atLeastHundred" "$err" ||
    fail "nested manifest ($target): expected atLeastHundred refuted"
  if grep -Eq "^([0-9]+)/\1 obligations discharged" "$out"; then
    fail "nested manifest ($target): a false proof"
  fi
  echo "PASS: prove refutes the nested-manifest build ($target)"
  rc="$(run "$lyric_bin" run --target "$target" nest/src/tool/limits.l)"
  [ "$rc" -ne 0 ] || fail "nested manifest ($target): running it must violate the postcondition"
  echo "PASS: run violates the postcondition, as the proof says ($target)"
done

echo "single-file features e2e passed"
