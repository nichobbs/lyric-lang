#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# cli-args-e2e.sh — command-line arguments the CLI must reject rather than
# ignore, end to end through the CLI.
#
#   LYRIC_BIN=<lyric> bash scripts/ci/cli-args-e2e.sh
#
#   * An option a subcommand does not take is an error, not a source path
#     (#8321), and a command that takes one source file rejects a second.
#   * `--features` naming a feature the manifest's `[features]` table does not
#     declare is F0050 from build/run/test/prove, single-file and project mode,
#     with no output written; a manifest with no `[features]` table declares
#     none (#8362).  Declared names still build.
#
# Invoked from `compiler-self-tests-batch.sh`.  Needs dotnet only.
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

mkdir -p "$work/loose" "$work/proj/src/p" "$work/nofeat/src/p"

printf 'package Hello\n\nfunc main(): Unit {\n  println("hi")\n}\n' > "$work/loose/hello.l"
cp "$work/loose/hello.l" "$work/loose/other.l"
printf '@test_module\npackage HelloTests\n\nimport Std.Testing\n\ntest "two" {\n  assertEqualInt(1 + 1, 2, "two")\n}\n' > "$work/loose/hello_tests.l"

# ── 1. Unknown options and surplus positionals ──────────────────────────────
cd "$work/loose"

expect_unknown_option() {
  local label="$1"; shift
  local rc
  rc="$(run "$@")"
  [ "$rc" -ne 0 ] || fail "$label: expected a non-zero exit"
  grep -q "unknown option '--bogus-flag'" "$err" || fail "$label: expected an unknown-option error"
  if grep -q "Unhandled exception" "$out" "$err"; then
    fail "$label: crashed"
  fi
  echo "PASS: $label"
}
for cmd in build run test fmt lint doc check clean bench prove; do
  expect_unknown_option "$cmd --bogus-flag" "$lyric_bin" "$cmd" --bogus-flag hello.l
done
[ ! -e hello.dll ] || fail "an unknown option must not leave build output"

expect_extra_positional() {
  local label="$1"; shift
  local rc
  rc="$(run "$@")"
  [ "$rc" -ne 0 ] || fail "$label: expected a non-zero exit"
  grep -q "expected one source file, got 2" "$err" || fail "$label: expected the surplus-argument error"
  echo "PASS: $label"
}
expect_extra_positional "build a.l b.l" "$lyric_bin" build hello.l other.l
[ ! -e hello.dll ] || fail "build a.l b.l: no output may be written"
expect_extra_positional "test a.l b.l" "$lyric_bin" test hello_tests.l hello.l
expect_extra_positional "lint a.l b.l" "$lyric_bin" lint hello.l other.l

# ── 2. F0050: a --features name the manifest does not declare ───────────────
printf '[package]\nname = "ArgsProj"\nversion = "0.1.0"\n\n[project]\nname = "ArgsProj"\noutput = "single"\noutput_assembly = "ArgsProj.dll"\n\n[project.packages]\n"P" = "src/p"\n\n[features]\ndefault = []\nwide = []\n' > "$work/proj/lyric.toml"
printf 'package P\n\npub func one(): Int {\n  1\n}\n' > "$work/proj/src/p/p.l"
printf 'package Tool\n\nfunc main(): Unit {\n  println("tool")\n}\n' > "$work/proj/tool.l"
cp "$work/loose/hello_tests.l" "$work/proj/tool_tests.l"

printf '[package]\nname = "NoFeat"\nversion = "0.1.0"\n\n[project]\nname = "NoFeat"\noutput = "single"\noutput_assembly = "NoFeat.dll"\n\n[project.packages]\n"P" = "src/p"\n' > "$work/nofeat/lyric.toml"
cp "$work/proj/src/p/p.l" "$work/nofeat/src/p/p.l"
cp "$work/proj/tool.l" "$work/nofeat/tool.l"

expect_f0050() {
  local label="$1" name="$2" hint="$3"; shift 3
  local rc
  rc="$(run "$@")"
  [ "$rc" -ne 0 ] || fail "$label: expected a non-zero exit"
  grep -q "error\[F0050\]: --features $name not declared in .*lyric.toml ($hint" "$err" ||
    fail "$label: expected F0050 naming $name"
  if grep -q "Unhandled exception" "$out" "$err"; then
    fail "$label: crashed"
  fi
  echo "PASS: $label"
}

cd "$work/proj"
expect_f0050 "build project --features wdie" wdie "declared features: " "$lyric_bin" build --manifest lyric.toml --features wdie
[ ! -e bin ] || fail "build project --features wdie: no output may be written"
expect_f0050 "build project --features wide,wdie" wdie "declared features: " "$lyric_bin" build --manifest lyric.toml --features wide,wdie
expect_f0050 "build single file --features wdie" wdie "declared features: " "$lyric_bin" build tool.l --features wdie
expect_f0050 "run single file --features wdie" wdie "declared features: " "$lyric_bin" run tool.l --features wdie
expect_f0050 "test single file --features wdie" wdie "declared features: " "$lyric_bin" test tool_tests.l --features wdie
expect_f0050 "prove single file --features wdie" wdie "declared features: " "$lyric_bin" prove tool.l --features wdie

rc="$(run "$lyric_bin" build tool.l --features wide -o "$work/tool.dll")"
[ "$rc" -eq 0 ] || fail "build --features wide: a declared feature must build"
echo "PASS: build --features wide"
rc="$(run "$lyric_bin" run tool.l --features wide)"
[ "$rc" -eq 0 ] || fail "run --features wide: a declared feature must run"
echo "PASS: run --features wide"

# A manifest with no `[features]` table declares no features.
cd "$work/nofeat"
expect_f0050 "build project, manifest without [features]" wide "the manifest has no \[features\] table" \
  "$lyric_bin" build --manifest lyric.toml --features wide
expect_f0050 "run single file, manifest without [features]" wide "the manifest has no \[features\] table" \
  "$lyric_bin" run tool.l --features wide
rc="$(run "$lyric_bin" run tool.l)"
[ "$rc" -eq 0 ] || fail "run without --features: expected success"
echo "PASS: run without --features, manifest without [features]"

echo "cli-args-e2e: all checks passed"
