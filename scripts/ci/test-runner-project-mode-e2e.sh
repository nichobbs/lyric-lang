#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# test-runner-project-mode-e2e.sh — end-to-end test of project-mode
# `lyric test` selection and compilation (#8648).
#
#   BUILD_CONFIG=Release bash scripts/ci/test-runner-project-mode-e2e.sh
#
# Drives the real CLI over throwaway projects and checks:
#   - `--suite` runs only the named [project.tests] entries; an undeclared
#     name and `--suite` with a test file are usage errors (exit 1).
#   - `--filter` that selects no test in an entry skips that entry's compile
#     ("not compiled") and the summary counts it as "not run"; single-file
#     mode does the same.
#   - On dotnet the [project.packages] library is built once and linked by
#     every entry that does not merge into a library package; an entry the
#     linked build cannot serve (a non-literal `pub val`, #6133, read bare or
#     qualified) is compiled with the library instead, with a note; a merged
#     entry still reaches non-`pub` items; a package-private extern type in a
#     `pub` signature binds with its CLR type; a restored enum case named like
#     a stdlib one (`Other`) keeps the restored enum's ordinal.
#   - A library that does not compile fails every linking entry, with its
#     errors printed once.
#   - On JVM every entry still compiles with the library (no shared build).
# Invoked from `compiler-self-tests-batch.sh` (whose CI job has Java 21).
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

BUILD_CONFIG="${BUILD_CONFIG:-Debug}"
lyric_bin="${LYRIC_BIN:-$REPO_ROOT/bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric}"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin; cannot run the project-mode lyric test e2e" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

proj="$work/proj"
mkdir -p "$proj/src" "$proj/tests"
cat > "$proj/lyric.toml" <<'TOML'
[package]
name = "RunnerE2e"
version = "0.1.0"

[project]
name = "RunnerE2e"
output = "single"
output_assembly = "RunnerE2e.dll"

[project.packages]
"RunnerE2e.Lib" = "src/lib.l"
"RunnerE2e.Shapes" = "src/shapes.l"
"RunnerE2e.Ext" = "src/ext.l"
"RunnerE2e.Kinds" = "src/kinds.l"

[project.tests]
"RunnerE2e.MathTests" = "tests/math_tests.l"
"RunnerE2e.ShapeTests" = "tests/shape_tests.l"
"RunnerE2e.InternalTests" = "tests/internal_tests.l"
"RunnerE2e.BareValTests" = "tests/bare_val_tests.l"
"RunnerE2e.QualifiedValTests" = "tests/qualified_val_tests.l"
"RunnerE2e.ExtTests" = "tests/ext_tests.l"
"RunnerE2e.KindsTests" = "tests/kinds_tests.l"
TOML
cat > "$proj/src/lib.l" <<'EOF'
package RunnerE2e.Lib

pub val greeting: String = "hello"

pub val limit: Int = 40

pub func add(a: in Int, b: in Int): Int = a + b

func secret(): Int = 41
EOF
cat > "$proj/src/shapes.l" <<'EOF'
package RunnerE2e.Shapes

import RunnerE2e.Lib

pub union Shape {
  case Circle(r: Int)
  case Square(side: Int)
}

pub record Box[T] {
  value: T
}

pub func area(s: in Shape): Int {
  match s {
    case Circle(r) -> 3 * r * r
    case Square(side) -> add(side * side, 0)
  }
}
EOF
# A package-private extern type in `pub` signatures: a linked entry must call
# these with the CLR types they were built with, not `object`.  It binds a .NET
# type, so it is gated to dotnet.
cat > "$proj/src/ext.l" <<'EOF'
@cfg(target = "dotnet")
package RunnerE2e.Ext

extern type Sb = "System.Text.StringBuilder"

pub func newSb(): Sb {
  return Sb.new()
}

pub func appendLen(s: in Sb, text: in String): Int {
  s.Append(text)
  s.Length
}
EOF
cat > "$proj/tests/ext_tests.l" <<'EOF'
@cfg(target = "dotnet")
@test_module
package RunnerE2e.ExtTests

import Std.Testing
import RunnerE2e.Ext

test "extern type crosses the shared build" {
  assertEqualInt(appendLen(newSb(), "abc"), 3, "StringBuilder length")
}
EOF
# An enum whose case shares its name with a stdlib enum case
# (`Std.File.EntryKind.Other`): a linked entry must use the restored enum's
# ordinal as a call argument, in a match (also on a field of a library record),
# in a comparison and in an annotated binding.  The distinct type `Score`
# checks that a linked entry can call its `from` constructor and `toInt`
# conversion, and `Bounded` that it checks a library record's invariant.
cat > "$proj/src/kinds.l" <<'EOF'
package RunnerE2e.Kinds

pub type Score = Int derives Add, Compare

pub func addScores(a: in Score, b: in Score): Score = a + b

pub enum Category {
  case Alpha
  case Other
}

pub record Tagged {
  category: Category
}

pub record Bounded {
  n: Int
  invariant: n >= 1
}

pub func categoryName(c: in Category): String {
  match c {
    case Alpha -> return "alpha"
    case Other -> return "other"
  }
}
EOF
cat > "$proj/tests/kinds_tests.l" <<'EOF'
@test_module
package RunnerE2e.KindsTests

import Std.Core
import Std.Testing
import RunnerE2e.Kinds

func describe(c: in Category): String {
  match c {
    case Alpha -> return "a"
    case Other -> return "o"
  }
}

test "case passed to a library function" {
  assertTrue(categoryName(Other) == "other", "categoryName(Other)")
}

test "case matched in the test module" {
  assertTrue(describe(Other) == "o", "describe(Other)")
}

test "case compared and annotated" {
  val c: Category = Other
  assertTrue(c == Other, "c == Other")
  assertTrue(categoryName(c) == "other", "categoryName(c)")
}

test "case stored in a library record and matched" {
  val t = Tagged(category = Other)
  val name = match t.category {
    case Other -> "other"
    case _ -> "not other"
  }
  assertTrue(name == "other", "match on t.category")
}

test "a library record's invariant is checked at construction" {
  assertPanics("n = 0", () -> { val b = Bounded(n = 0) })
  assertEqualInt(Bounded(n = 3).n, 3, "n = 3")
}

test "distinct type constructed and converted" {
  assertEqualInt(addScores(Score.from(40), Score.from(2)).toInt(), 42, "Score")
}
EOF
cat > "$proj/tests/math_tests.l" <<'EOF'
@test_module
package RunnerE2e.MathTests

import Std.Testing
import RunnerE2e.Lib

test "add adds" {
  assertEqualInt(add(2, 3), 5, "2 + 3")
}

test "literal val crosses" {
  assertEqualInt(limit, 40, "inlined Int val")
}
EOF
cat > "$proj/tests/shape_tests.l" <<'EOF'
@test_module
package RunnerE2e.ShapeTests

import Std.Testing
import RunnerE2e.Shapes

test "circle area" {
  assertEqualInt(area(Circle(r = 2)), 12, "3*2*2")
}

test "generic box" {
  val b = Box(value = "x")
  assertTrue(b.value == "x", "box holds value")
}
EOF
cat > "$proj/tests/internal_tests.l" <<'EOF'
@test_module
package RunnerE2e.Lib

import Std.Testing

test "secret reached from a merged module" {
  assertEqualInt(secret(), 41, "non-pub item")
}
EOF
cat > "$proj/tests/bare_val_tests.l" <<'EOF'
@test_module
package RunnerE2e.BareValTests

import Std.Testing
import RunnerE2e.Lib

test "bare string val" {
  assertTrue(greeting == "hello", "bare")
}
EOF
cat > "$proj/tests/qualified_val_tests.l" <<'EOF'
@test_module
package RunnerE2e.QualifiedValTests

import Std.Testing
import RunnerE2e.Lib

test "qualified string val" {
  assertTrue(RunnerE2e.Lib.greeting == "hello", "qualified")
}
EOF

# A library with a type error, linked by two entries.
broken="$work/broken"
mkdir -p "$broken/src" "$broken/tests"
cat > "$broken/lyric.toml" <<'TOML'
[package]
name = "BrokenLib"
version = "0.1.0"

[project]
name = "BrokenLib"
output = "single"
output_assembly = "BrokenLib.dll"

[project.packages]
"BrokenLib" = "src/lib.l"

[project.tests]
"BrokenLib.ATests" = "tests/a_tests.l"
"BrokenLib.BTests" = "tests/b_tests.l"
TOML
cat > "$broken/src/lib.l" <<'EOF'
package BrokenLib

pub func one(): Int = "not an Int"
EOF
for t in a b; do
  cat > "$broken/tests/${t}_tests.l" <<EOF
@test_module
package BrokenLib.$(echo "$t" | tr a-z A-Z)Tests

import Std.Testing
import BrokenLib

test "one" {
  assertEqualInt(one(), 1, "one")
}
EOF
done

# A single test file outside any project.
single="$work/single/filtered_tests.l"
mkdir -p "$work/single"
cat > "$single" <<'EOF'
@test_module
package FilteredSingle

import Std.Testing

test "alpha" {
  assertTrue(true, "a")
}
EOF

failures=0
out="$work/out.txt"
fail() {
  echo "FAIL [$1]: $2"
  echo "---- output [$1] ----"; cat "$out"; echo "----"
  failures=$((failures + 1))
}
run() {
  rc=0
  "$lyric_bin" test "$@" > "$out" 2>&1 || rc=$?
}
count() { grep -cF -- "$1" "$out" || true; }

m="$proj/lyric.toml"

label="dotnet full run"
run --manifest "$m"
if [ "$rc" -ne 0 ]; then fail "$label" "exit $rc"
elif [ "$(count '== building the [project.packages] library once')" != 1 ]; then fail "$label" "library not built exactly once"
elif [ ! -f "$proj/.lyric-test/LyricTestLibrary.dll" ]; then fail "$label" "no shared library assembly"
elif [ "$(count 'note: ')" != 2 ]; then fail "$label" "expected a fallback note for each non-literal pub val entry"
elif grep -q 'error\[' "$out"; then fail "$label" "a discarded linked attempt's errors were printed"
elif ! grep -q "^== summary: 7 passed, 0 failed$" "$out"; then fail "$label" "summary"
else echo "ok   [$label]"; fi

label="--suite selection"
run --manifest "$m" --suite RunnerE2e.ShapeTests --suite RunnerE2e.InternalTests
if [ "$rc" -ne 0 ]; then fail "$label" "exit $rc"
elif [ "$(grep -c '^== RunnerE2e\.' "$out")" != 2 ]; then fail "$label" "expected exactly the two named entries"
elif ! grep -q "^== summary: 2 passed, 0 failed$" "$out"; then fail "$label" "summary"
else echo "ok   [$label]"; fi

label="--suite unknown name"
run --manifest "$m" --suite Nope
if [ "$rc" -ne 1 ]; then fail "$label" "expected exit 1, got $rc"
elif ! grep -q "is not a \[project.tests\] entry" "$out" || ! grep -q "RunnerE2e.MathTests" "$out"; then fail "$label" "message should name the declared entries"
else echo "ok   [$label]"; fi

label="--suite with a test file"
run "$proj/tests/math_tests.l" --suite RunnerE2e.MathTests
if [ "$rc" -ne 1 ]; then fail "$label" "expected exit 1, got $rc"
else echo "ok   [$label]"; fi

label="--filter skips entries it empties"
run --manifest "$m" --filter "circle"
if [ "$rc" -ne 0 ]; then fail "$label" "exit $rc"
elif [ "$(count 'none match --filter; not compiled')" != 6 ]; then fail "$label" "expected six entries not compiled"
elif ! grep -q "^== summary: 1 passed, 0 failed, 6 not run (no test matches --filter)$" "$out"; then fail "$label" "summary"
else echo "ok   [$label]"; fi

label="single-file --filter selects nothing"
run "$single" --filter zzz
if [ "$rc" -ne 0 ]; then fail "$label" "exit $rc"
elif [ "$(count '1 test(s), none match --filter; not compiled')" != 1 ]; then fail "$label" "expected the not-compiled line"
else echo "ok   [$label]"; fi

label="library that does not compile"
run --manifest "$broken/lyric.toml"
if [ "$rc" -ne 1 ]; then fail "$label" "expected exit 1, got $rc"
elif [ "$(count 'the [project.packages] library does not compile')" != 2 ]; then fail "$label" "both entries should fail on the library"
elif [ "$(grep -c 'src/lib.l: error' "$out")" != 1 ]; then fail "$label" "library errors should print once"
else echo "ok   [$label]"; fi

label="jvm compiles each entry with the library"
run --manifest "$m" --target jvm --suite RunnerE2e.MathTests --suite RunnerE2e.BareValTests
if [ "$rc" -ne 0 ]; then fail "$label" "exit $rc"
elif [ "$(count 'library once')" != 0 ]; then fail "$label" "no shared build on jvm"
elif ! grep -q "^== summary: 2 passed, 0 failed$" "$out"; then fail "$label" "summary"
else echo "ok   [$label]"; fi

if [ "$failures" -ne 0 ]; then
  echo "::error::$failures project-mode lyric test e2e case(s) failed (#8648)" >&2
  exit 1
fi
echo "project-mode lyric test e2e passed"
