#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# coverage-e2e.sh — end-to-end regression test for `lyric test --coverage`
# (#5294, D246).
#
#   BUILD_CONFIG=Release bash scripts/ci/coverage-e2e.sh
#
# The F#-era `coverage` CI job kept reporting green while collecting nothing,
# so this checks the report itself: a small project with known covered and
# uncovered lines must give the exact lcov on BOTH targets (dotnet and JVM
# share one instrumentation, so the two files must be identical), a Cobertura
# report with the same totals, and `--min-coverage` must fail the run when the
# total is under it.  Native is rejected with a pointer to #8553.  Invoked from
# `compiler-self-tests-batch.sh` (whose CI job has Java 21).
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

BUILD_CONFIG="${BUILD_CONFIG:-Debug}"
lyric_bin="${LYRIC_BIN:-$REPO_ROOT/bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric}"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin; skipping coverage e2e" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

proj="$work/proj"
mkdir -p "$proj/src" "$proj/tests"
cat > "$proj/lyric.toml" <<'TOML'
[package]
name = "CovProj"
version = "0.1.0"

[project]
name = "CovProj"
output = "single"
output_assembly = "CovProj.dll"

[project.packages]
"Calc" = "src/calc.l"

[project.tests]
"Calc.Tests" = "tests/calc_tests.l"
TOML
cat > "$proj/src/calc.l" <<'EOF'
package Calc

pub func classify(n: in Int): String {
  if n < 0 {
    return "negative"
  }
  if n == 0 {
    return "zero"
  }
  "positive"
}

pub func unused(): Int {
  1
}
EOF
cat > "$proj/tests/calc_tests.l" <<'EOF'
@test_module
package Calc.Tests

import Std.Testing
import Calc

test "negative" {
  assertEqual(classify(-1), "negative", "negative")
}

test "positive" {
  assertEqual(classify(5), "positive", "positive")
}
EOF

# The exact lcov: lines 4 (twice), 5, 7 and 10 ran once or twice; 8 and 14 never.
expected="$work/expected.info"
cat > "$expected" <<EOF
TN:
SF:$proj/src/calc.l
FN:3,classify
FN:13,unused
FNDA:2,classify
FNDA:0,unused
FNF:2
FNH:1
DA:4,2
DA:5,1
DA:7,1
DA:8,0
DA:10,1
DA:14,0
LF:6
LH:4
end_of_record
EOF

failures=0
fail() {
  echo "FAIL [$1]: $2"
  failures=$((failures + 1))
}

for target in dotnet jvm; do
  rm -rf "$proj/.lyric-test"
  out="$work/out-$target.txt"
  rc=0
  "$lyric_bin" test --manifest "$proj/lyric.toml" --target "$target" --coverage > "$out" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "$target" "lyric test --coverage exited $rc"
    cat "$out"
    continue
  fi
  if ! diff -u "$expected" "$proj/.lyric-test/coverage.info"; then
    fail "$target" "coverage.info differs from the expected lcov"
  fi
  xml="$proj/.lyric-test/coverage.xml"
  for needle in 'lines-covered="4" lines-valid="6"' '<line number="8" hits="0"/>' '<line number="4" hits="2"/>'; do
    if ! grep -qF -- "$needle" "$xml"; then
      fail "$target" "coverage.xml lacks $needle"
    fi
  done
  if ! grep -q "total: 66.7%" "$out"; then
    fail "$target" "console summary lacks 'total: 66.7%'"
  fi
  echo "ok   [coverage report, $target]"

  # 66.7% passes a 60 minimum and fails a 70 one.
  rc=0
  "$lyric_bin" test --manifest "$proj/lyric.toml" --target "$target" --coverage --min-coverage 60 > "$out" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "$target" "--min-coverage 60 should pass at 66.7% (exit $rc)"
  else
    echo "ok   [--min-coverage met, $target]"
  fi
  rc=0
  "$lyric_bin" test --manifest "$proj/lyric.toml" --target "$target" --coverage --min-coverage 70 > "$out" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    fail "$target" "--min-coverage 70 should fail at 66.7%"
  elif ! grep -q "under the required 70%" "$out"; then
    fail "$target" "--min-coverage failure does not say why"
  else
    echo "ok   [--min-coverage missed, $target]"
  fi
done

# A test module merged into the package under test (D245) counts the same lines.
merged="$work/merged"
mkdir -p "$merged/src" "$merged/tests"
cp "$proj/lyric.toml" "$merged/lyric.toml"
cp "$proj/src/calc.l" "$merged/src/calc.l"
cat > "$merged/tests/calc_tests.l" <<'EOF'
@test_module
package Calc

import Std.Testing

test "negative" {
  assertEqual(classify(-1), "negative", "negative")
}

test "positive" {
  assertEqual(classify(5), "positive", "positive")
}
EOF
sed "s|$proj|$merged|" "$expected" > "$work/expected-merged.info"
for target in dotnet jvm; do
  rc=0
  "$lyric_bin" test --manifest "$merged/lyric.toml" --target "$target" --coverage > "$work/merged-$target.txt" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "merged $target" "exited $rc"
    cat "$work/merged-$target.txt"
  elif ! diff -u "$work/expected-merged.info" "$merged/.lyric-test/coverage.info"; then
    fail "merged $target" "coverage.info differs"
  else
    echo "ok   [merged test module, $target]"
  fi
done

# Single file: a test module's helpers are the code under test.
single="$work/single"
mkdir -p "$single"
cat > "$single/helper_tests.l" <<'EOF'
@test_module
package HelperTests

import Std.Testing

func double(x: in Int): Int {
  x * 2
}

func never(): Int {
  3
}

test "double" {
  assertEqualInt(double(4), 8, "double")
}
EOF
for target in dotnet jvm; do
  rc=0
  "$lyric_bin" test "$single/helper_tests.l" --target "$target" --coverage > "$work/single-$target.txt" 2>&1 || rc=$?
  info="$single/.lyric-test/coverage.info"
  if [ "$rc" -ne 0 ]; then
    fail "single-file $target" "exited $rc"
    cat "$work/single-$target.txt"
  elif ! grep -q "^DA:7,1$" "$info" || ! grep -q "^DA:11,0$" "$info" || ! grep -q "^LH:1$" "$info"; then
    fail "single-file $target" "unexpected lcov"
    cat "$info"
  else
    echo "ok   [single-file coverage, $target]"
  fi
done

# Native is not supported yet and says so, naming the issue.
rc=0
"$lyric_bin" test "$single/helper_tests.l" --target native --coverage > "$work/native.txt" 2>&1 || rc=$?
if [ "$rc" -eq 0 ] || ! grep -q "#8553" "$work/native.txt"; then
  fail "native" "--coverage on --target native should be rejected with a pointer to #8553"
else
  echo "ok   [native rejected]"
fi

# A run that measured nothing is an error, not a pass.
rc=0
"$lyric_bin" test "$work/proj/tests/calc_tests.l" --coverage > "$work/none.txt" 2>&1 || rc=$?
if [ "$rc" -eq 0 ] || ! grep -q "no code under test was instrumented" "$work/none.txt"; then
  fail "nothing to measure" "should fail with 'no code under test was instrumented'"
else
  echo "ok   [nothing measured is an error]"
fi

if [ "$failures" -ne 0 ]; then
  echo "::error::$failures coverage e2e case(s) failed (#5294)" >&2
  exit 1
fi
echo "coverage e2e passed (project + single file, dotnet + jvm)"
