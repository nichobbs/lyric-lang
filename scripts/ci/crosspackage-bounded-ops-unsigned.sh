#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# crosspackage-bounded-ops-unsigned.sh — operators in another package's
# generic, lowered for the caller's types and the generic's own unsigned
# operands (#8530, #8019).  Run on both targets, against a restored
# dependency and against a source dependency.
#
# 1. #8530: `sum2[T] where T: Add` is declared in a library and called with a
#    distinct type (`Score`) and a homogeneous record (`Vec2`) the CALLER
#    declares.  The specialisation is re-checked in the library's scope with
#    the caller's types added to it, so `a + b` is lowered for the caller's
#    type instead of being the hard error M0008.
# 2. #8019: `hashMix[T]` has concrete `UInt` locals independent of `T` and is
#    specialised with a signed type argument.  The specialisation is re-checked
#    because its body spells `UInt`, so `/`, `%` and `>` on values at or above
#    2^31 are unsigned (before: -184995328 0 false -1294967296 on the JVM).
#
# Usage: BUILD_CONFIG=Release scripts/ci/crosspackage-bounded-ops-unsigned.sh
# ---------------------------------------------------------------------------
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
lyric_bin="$REPO_ROOT/bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG:-Debug}/net10.0/lyric"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin"
  exit 1
fi
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/lib/src" "$work/app/src" "$work/app/tests"
cat > "$work/lib/lyric.toml" <<'TOML'
[package]
name = "BU.Lib"
version = "0.1.0"

[project]
name = "BU.Lib"
output = "single"
output_assembly = "BULib.dll"

[project.packages]
"BULib" = "src/lib.l"
TOML
cat > "$work/lib/src/lib.l" <<'L'
package BULib

pub func sum2[T](a: in T, b: in T): T
  where T: Add
{
  a + b
}

pub func bigger[T](a: in T, b: in T): T
  where T: Compare
{
  if a > b { a } else { b }
}

pub func hashMix[T](x: in T): String {
  val a: UInt = 3000000000u32
  val b: UInt = 7u32
  val q = a / b
  val r = a % b
  val gt = a > b
  "${q} ${r} ${gt} ${a}"
}
L
cat > "$work/app/lyric.toml" <<'TOML'
[package]
name = "BU.App"
version = "0.1.0"

[project]
name = "BU.App"
output = "single"
output_assembly = "BUApp.dll"

[project.packages]
"BUApp" = "src/app.l"

[project.tests]
"BUApp.Tests" = "tests/app_tests.l"

[dependencies]
"BU.Lib" = { path = "../lib" }
TOML
cat > "$work/app/src/app.l" <<'L'
package BUApp

import BULib

pub type Score = Int derives Add, Compare

@derive(Add)
pub record Vec2 {
  x: Int
  y: Int
}

pub func addScores(a: in Score, b: in Score): Score {
  sum2(a, b)
}

pub func addVecs(a: in Vec2, b: in Vec2): Vec2 {
  sum2(a, b)
}

pub func biggerScore(a: in Score, b: in Score): Score {
  bigger(a, b)
}

pub func mixed(): String {
  hashMix(1)
}
L
cat > "$work/app/tests/app_tests.l" <<'L'
@test_module
package BUApp.Tests

import Std.Core
import Std.Testing
import BUApp

test "an operator on a caller's distinct type lowers in the library's generic" {
  assertEqual(toString(addScores(Score.from(40), Score.from(2))), "42", "Score")
  assertEqual(toString(biggerScore(Score.from(3), Score.from(9))), "9", "bigger Score")
}

test "an operator on a caller's record lowers in the library's generic" {
  val v = addVecs(Vec2(x = 1, y = 2), Vec2(x = 10, y = 20))
  assertEqualInt(v.x, 11, "x")
  assertEqualInt(v.y, 22, "y")
}

test "a library generic's own UInt operands are unsigned at a signed type argument" {
  assertEqual(mixed(), "428571428 4 true 3000000000", "unsigned")
}
L
"$lyric_bin" build --manifest "$work/lib/lyric.toml"
for target in dotnet jvm; do
  echo "=== --target $target"
  "$lyric_bin" test --target "$target" --manifest "$work/app/lyric.toml"
done
echo "bounded operators and unsigned operands cross the package boundary on both targets"
