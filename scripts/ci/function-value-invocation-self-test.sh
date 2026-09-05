#!/usr/bin/env bash
set -euo pipefail
if [ ! -d .bootstrap/stage1 ] || [ ! -f .bootstrap/stage1/Lyric.Lyric.Cli.dll ]; then
  echo "::error::stage 1 bundle missing; skipping function-value invocation test"
  exit 1
fi
lyric_bin="bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin; skipping function-value invocation test"
  exit 1
fi
dir="$(mktemp -d)"
pos="$dir/hof.l"
cat > "$pos" <<'LYRIC'
package Hof
import Std.Core
func apply0(f: in () -> Int): Int { f() }
func twice(f: in () -> Int): Int { f() + f() }
func applyS(f: in () -> String): String { f() }
func runV(f: in () -> Unit): Unit { f() }
func five(): Int { 5 }
func main(): Int {
  println("a0=" + toString(apply0({ -> 42 })))
  println("tw=" + toString(twice({ -> five() })))
  println("aS=" + applyS({ -> "hi" }))
  runV({ -> println("voidcb") })
  0
}
LYRIC
out="$("$lyric_bin" run "$pos" 2>&1)" || { echo "::error::function-value HOF program failed to run"; echo "$out"; exit 1; }
for expect in "a0=42" "tw=10" "aS=hi" "voidcb"; do
  if ! grep -qx "$expect" <<< "$out"; then
    echo "::error::expected '$expect' in function-value HOF output"; echo "$out"; exit 1
  fi
done
echo "OK: zero-argument function-value invocation produces correct results."
# Parameter-taking lambdas (#1939): a lambda passed directly to a typed
# `(…) -> R` parameter has its boxed args unboxed — both an explicit
# annotation and an un-annotated param (type propagated from the HOF
# signature) must run and produce correct results.
ann="$dir/ann.l"
cat > "$ann" <<'LYRIC'
package Ann
import Std.Core
func apply1(f: in (Int) -> Int, x: in Int): Int { f(x) }
func apply2(f: in (Int, Int) -> Int, a: in Int, b: in Int): Int { f(a, b) }
func applyB(f: in (Int) -> Bool, x: in Int): Bool { f(x) }
func main(): Int {
  println("a1=" + toString(apply1({ x: Int -> x + 1 }, 10)))
  println("u1=" + toString(apply1({ x -> x + 1 }, 10)))
  println("u2=" + toString(apply2({ a, b -> a * b }, 6, 7)))
  println("uB=" + toString(applyB({ x -> x > 5 }, 3)))
  0
}
LYRIC
aout="$("$lyric_bin" run "$ann" 2>&1)" || { echo "::error::param-taking HOF program failed to run"; echo "$aout"; exit 1; }
# #5552: Bool.toString() is pinned to lowercase "true"/"false" now
# (was the BCL Boolean.ToString() default, "True").
for expect in "a1=11" "u1=11" "u2=42" "uB=false"; do
  if ! grep -qx "$expect" <<< "$aout"; then
    echo "::error::expected '$expect' in param-taking HOF output"; echo "$aout"; exit 1
  fi
done
echo "OK: annotated and propagated parameter-taking lambdas produce correct results."
# An un-annotated param-using lambda NOT passed directly to a HOF (so no
# type can be propagated) must fail loud (#1939), not read garbage.
neg="$dir/pneg.l"
cat > "$neg" <<'LYRIC'
package PNeg
import Std.Core
func main(): Int { val f = { x -> x + 1 }; println("made"); 0 }
LYRIC
if "$lyric_bin" build --target dotnet "$neg" > "$dir/pneg.out" 2>&1; then
  echo "::error::un-typed param-using lambda compiled — the #1939 diagnostic did not fire"; cat "$dir/pneg.out"; exit 1
fi
if ! grep -qi "un-annotated parameter" "$dir/pneg.out"; then
  echo "::error::un-typed param-using lambda failed without the expected #1939 diagnostic"; cat "$dir/pneg.out"; exit 1
fi
echo "OK: un-typed param-using lambda (no annotation, no HOF propagation) fails loud (#1939)."

