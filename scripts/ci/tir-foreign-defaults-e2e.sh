#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# tir-foreign-defaults-e2e.sh - a call that leaves out an argument whose default
# another package declares builds into TIR (docs/70 §6.3, D482).
#
# A two-package project: package A declares a function with literal and `newList()`
# defaults and a record with field defaults; package B calls them leaving the
# defaulted arguments out.  `lyric build --verify-ir` must build every body of B
# and the verifier must report nothing.  Each case also runs without --verify-ir
# and the program's exit code is checked, so the default's value is the declared one.
#
# Usage: tir-foreign-defaults-e2e.sh [path/to/lyric]
# ---------------------------------------------------------------------------
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LYRIC="${1:-$REPO_ROOT/bin/lyric}"
# The script builds from a temporary directory, so the binary must not be a relative path.
LYRIC="$(cd "$(dirname "$LYRIC")" && pwd)/$(basename "$LYRIC")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export NuGetAudit=false

mkdir -p "$WORK/src/a" "$WORK/src/b"
cat > "$WORK/lyric.toml" <<'TOML'
[package]
name = "ForeignDefaults"
version = "0.1.0"

[project]
name = "ForeignDefaults"
output = "single"
output_assembly = "ForeignDefaults.dll"

[project.packages]
"A" = "src/a"
"B" = "src/b"
TOML
cat > "$WORK/src/a/a.l" <<'LYRIC'
package A
import Std.Core
import Std.Collections

pub func f(x: in Int, flag: in Bool = false, n: in Int = 3): Int {
  if flag { x + n } else { x }
}

pub func g(x: in Int, l: in List[Int] = newList()): Int {
  x + l.count
}

pub func h(x: in Int, y: in Int = 4, z: in Int = 5): Int {
  x * 100 + y * 10 + z
}

pub record R {
  a: Int
  b: Int = 5
  s: String = "hi"
}
LYRIC

fail=0
# Each case: the expression in B's main, and the exit code it must produce.
cases=("f(1)|1" "f(1, true)|4" "g(7)|7" "R(a = 1).b|5" "R(a = 1).s.length|2" "h(1)|145" "h(1, 2)|125")
for c in "${cases[@]}"; do
  expr="${c%%|*}"
  want="${c##*|}"
  cat > "$WORK/src/b/b.l" <<LYRIC
package B
import A
import Std.Core
import Std.Collections

pub func main(): Int {
  $expr
}
LYRIC
  log="$WORK/census.log"
  (cd "$WORK" && "$LYRIC" build --verify-ir --manifest lyric.toml --target dotnet >"$log" 2>&1)
  if ! grep -q "TIR build census \[.*src/b/b.l\]: 1 of 1 function bodies built" "$log"; then
    echo "FAIL ($expr): the body of B did not build"; grep -E "first error|no builder case" "$log" | head -3; fail=1; continue
  fi
  if ! grep -q "I0003 census \[.*src/b/b.l\]: 0 diagnostic" "$log"; then
    echo "FAIL ($expr): the verifier rejected the built body"; grep -E "I0003" "$log" | head -3; fail=1; continue
  fi
  (cd "$WORK" && "$LYRIC" build --manifest lyric.toml --target dotnet >"$log" 2>&1) || { echo "FAIL ($expr): the build failed"; tail -3 "$log"; fail=1; continue; }
  (cd "$WORK" && dotnet bin/ForeignDefaults.dll >/dev/null 2>&1)
  got=$?
  if [[ "$got" != "$want" ]]; then
    echo "FAIL ($expr): exit code $got, want $want"; fail=1; continue
  fi
  echo "ok   $expr -> $want"
done
exit $fail
