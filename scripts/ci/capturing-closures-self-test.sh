#!/usr/bin/env bash
set -euo pipefail
if [ ! -d .bootstrap/stage1 ] || [ ! -f .bootstrap/stage1/Lyric.Lyric.Cli.dll ]; then
  echo "::error::stage 1 bundle missing; skipping capturing-closures test"
  exit 1
fi
lyric_bin="bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin; skipping capturing-closures test"
  exit 1
fi
dir="$(mktemp -d)"
pos="$dir/cap.l"
cat > "$pos" <<'LYRIC'
package Cap
import Std.Core
func apply0(f: in () -> Int): Int { f() }
func applyS(f: in () -> String): String { f() }
func apply1(f: in (Int) -> Int, x: in Int): Int { f(x) }
func main(): Int {
  val a = 3
  val b = 4
  println("c1=" + toString(apply0({ -> a * b + 1 })))
  val name = "world"
  println("c2=" + applyS({ -> "hi " + name }))
  val base = 100
  println("c3=" + toString(apply1({ x -> x + base }, 5)))
  0
}
LYRIC
out="$("$lyric_bin" run "$pos" 2>&1)" || { echo "::error::capturing-closure program failed to run"; echo "$out"; exit 1; }
for expect in "c1=13" "c2=hi world" "c3=105"; do
  if ! grep -qx "$expect" <<< "$out"; then
    echo "::error::expected '$expect' in capturing-closure output"; echo "$out"; exit 1
  fi
done
echo "OK: by-value capture of immutable bindings produces correct results."
# By-reference capture of a `var` (#1479 v2): a hoisted heap cell is
# shared, so a mutation inside the closure is visible outside (m1=2) and
# an external mutation is visible inside a closure captured earlier
# (m2=10).
ref="$dir/capref.l"
cat > "$ref" <<'LYRIC'
package CapRef
import Std.Core
func run(f: in () -> Unit): Unit { f() }
func apply0(f: in () -> Int): Int { f() }
func main(): Int {
  var count = 0
  run({ -> count = count + 1 })
  run({ -> count = count + 1 })
  println("m1=" + toString(count))
  var n = 1
  val get = { -> n + 0 }
  n = 10
  println("m2=" + toString(apply0(get)))
  0
}
LYRIC
rout="$("$lyric_bin" run "$ref" 2>&1)" || { echo "::error::by-ref capturing closure failed to run"; echo "$rout"; exit 1; }
for expect in "m1=2" "m2=10"; do
  if ! grep -qx "$expect" <<< "$rout"; then
    echo "::error::expected '$expect' in by-ref capture output"; echo "$rout"; exit 1
  fi
done
echo "OK: by-reference (\`var\`) capture shares a mutable cell across the closure boundary."


