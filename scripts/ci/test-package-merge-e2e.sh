#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test-package-merge-e2e.sh — end-to-end regression test for `lyric test`
# merging a `@test_module` into the package it declares, and for
# `lyric test --doctests` (#678, D245).
#
#   BUILD_CONFIG=Release bash scripts/ci/test-package-merge-e2e.sh
#
# A `@test_module` whose `package` is a `[project.packages]` entry is compiled
# as one more file of that package, so its tests reach the package's non-`pub`
# items (a package of several files included).  A test module of another
# package still sees only `pub` items.  `--doctests` runs the ```lyric blocks
# of `///` comments as tests of their package.  Every case runs on dotnet and
# jvm, in manifest mode and as a single file.  Invoked from
# `compiler-self-tests-batch.sh` (whose CI job has Java 21).
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

BUILD_CONFIG="${BUILD_CONFIG:-Debug}"
lyric_bin="${LYRIC_BIN:-$REPO_ROOT/bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric}"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin; skipping test package merge e2e" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

proj="$work/proj"
mkdir -p "$proj/src/account" "$proj/tests"
cat > "$proj/lyric.toml" <<'TOML'
[package]
name = "MergeProj"
version = "0.1.0"

[project]
name = "MergeProj"
output = "single"
output_assembly = "MergeProj.dll"

[project.packages]
"Account" = "src/account"
"Shape" = "src/shape.l"

[project.tests]
"Account.Tests" = "tests/account_tests.l"
TOML
cat > "$proj/src/account/account.l" <<'EOF'
package Account

val hiddenRate: Int = 3

func secret(): Int {
  42
}

pub func balance(): Int {
  secret() + hiddenRate
}
EOF
cat > "$proj/src/account/ledger.l" <<'EOF'
package Account

func ledgerSecret(): Int {
  7
}
EOF
cat > "$proj/tests/account_tests.l" <<'EOF'
@test_module
package Account

import Std.Testing
import Account.{balance}

test "reaches a non-pub function" {
  assertEqualInt(secret(), 42, "secret")
}

test "reaches a non-pub val" {
  assertEqualInt(hiddenRate, 3, "hiddenRate")
}

test "reaches a non-pub function of a second file" {
  assertEqualInt(ledgerSecret(), 7, "ledgerSecret")
}

test "reaches the pub api" {
  assertEqualInt(balance(), 45, "balance")
}
EOF
# A test module of ANOTHER package sees only pub items.
cat > "$proj/tests/control_tests.l" <<'EOF'
@test_module
package Account.Control

import Std.Testing
import Account

test "cannot reach a non-pub function" {
  assertEqualInt(secret(), 42, "secret")
}
EOF
cat > "$proj/src/shape.l" <<'EOF'
package Shape

func hidden(): Int {
  10
}

/// Doubles a number.
///
/// ```lyric
/// import Std.Testing
/// import Shape.{double}
///
/// assertEqualInt(double(2), 4, "double")
/// assertEqualInt(hidden(), 10, "doctests reach non-pub items")
/// ```
pub func double(x: in Int): Int {
  x * 2
}

/// Not run.
///
/// ```lyric,no_test
/// this is not code
/// ```
pub func untested(): Int {
  0
}
EOF

failproj="$work/failproj"
mkdir -p "$failproj/src"
cat > "$failproj/lyric.toml" <<'TOML'
[package]
name = "FailDoc"
version = "0.1.0"

[project]
name = "FailDoc"
output = "single"
output_assembly = "FailDoc.dll"

[project.packages]
"Wrong" = "src/wrong.l"
TOML
cat > "$failproj/src/wrong.l" <<'EOF'
package Wrong

/// ```lyric
/// import Std.Testing
/// assertEqualInt(1 + 1, 3, "arithmetic")
/// ```
pub func one(): Int {
  1
}
EOF

failures=0
# run_case <label> <expected exit: 0|fail> <grep -E patterns that must match, ';'-separated>
#          <grep -E patterns that must NOT match, ';'-separated> -- <lyric test args...>
run_case() {
  local label="$1" expect="$2" present="$3" absent="$4"
  shift 5
  local out="$work/out.txt" rc=0
  "$lyric_bin" test "$@" > "$out" 2>&1 || rc=$?
  local ok=1 p
  if [ "$expect" = "0" ] && [ "$rc" -ne 0 ]; then
    echo "FAIL [$label]: lyric test exited $rc"; ok=0
  fi
  if [ "$expect" = "fail" ] && [ "$rc" -eq 0 ]; then
    echo "FAIL [$label]: lyric test unexpectedly passed"; ok=0
  fi
  IFS=';' read -ra want <<< "$present"
  for p in "${want[@]}"; do
    [ -z "$p" ] && continue
    if ! grep -qE -- "$p" "$out"; then
      echo "FAIL [$label]: expected output matching '$p'"; ok=0
    fi
  done
  IFS=';' read -ra gone <<< "$absent"
  for p in "${gone[@]}"; do
    [ -z "$p" ] && continue
    if grep -qE -- "$p" "$out"; then
      echo "FAIL [$label]: output must not match '$p'"; ok=0
    fi
  done
  if [ "$ok" -eq 1 ]; then
    echo "ok   [$label]"
  else
    echo "---- output [$label] ----"; cat "$out"; echo "----"
    failures=$((failures + 1))
  fi
}

merged='^ok 1 - reaches a non-pub function$;^ok 2 - reaches a non-pub val$;^ok 3 - reaches a non-pub function of a second file$;^ok 4 - reaches the pub api$;^1\.\.4$'
doc='^ok 1 - doctest .*shape\.l:[0-9]+$;^1\.\.1$'

for target in dotnet jvm; do
  m="$proj/lyric.toml"
  run_case "manifest merge, $target" 0 "$merged" "not ok" -- --manifest "$m" --target "$target"
  run_case "single-file merge, $target" 0 "$merged" "not ok" -- "$proj/tests/account_tests.l" --target "$target"
  run_case "other package sees pub only, $target" fail "T00|error" "^ok " -- \
    "$proj/tests/control_tests.l" --target "$target"
  run_case "manifest doctests, $target" 0 "$doc;^ok 1 - reaches a non-pub function$" "not ok" -- \
    --manifest "$m" --doctests --target "$target"
  run_case "single-file doctests, $target" 0 "$doc" "not ok" -- \
    "$proj/src/shape.l" --doctests --target "$target"
  run_case "failing doctest, $target" fail "^not ok 1 - doctest .*wrong\.l:[0-9]+$" "^ok " -- \
    --manifest "$failproj/lyric.toml" --doctests --target "$target"
  run_case "doctests are opt-in, $target" fail "not a @test_module" "doctest" -- \
    "$proj/src/shape.l" --target "$target"
done

if [ "$failures" -ne 0 ]; then
  echo "::error::$failures test package merge / doctest e2e case(s) failed (#678)" >&2
  exit 1
fi
echo "test package merge and doctests e2e passed (manifest + single-file, dotnet + jvm)"
