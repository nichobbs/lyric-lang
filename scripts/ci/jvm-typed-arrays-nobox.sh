#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# jvm-typed-arrays-nobox.sh: a numeric `array[N, T]` is a typed Java array
# on --target jvm (#8041), so arithmetic over its elements boxes nothing.
#
# Builds a small program, checks its output, and disassembles the functions
# that work on arrays: each must take and return the typed array (`[F`,
# `[I`), and none may call a wrapper `valueOf` (boxing) or touch `ArrayList`.
#
#   bash scripts/ci/jvm-typed-arrays-nobox.sh [lyric-bin]
# ---------------------------------------------------------------------------
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_CONFIG="${BUILD_CONFIG:-Debug}"
LYRIC="${1:-$ROOT/bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric}"
[ -x "$LYRIC" ] || LYRIC="$ROOT/bin/lyric"
[ -x "$LYRIC" ] || { echo "::error::lyric binary not found"; exit 1; }
JAVAP="$(command -v javap || true)"
if [ -z "$JAVAP" ] && [ -n "${JAVA_HOME:-}" ]; then
  JAVAP="$JAVA_HOME/bin/javap"
fi
[ -x "$JAVAP" ] || { echo "::error::javap not found (set JAVA_HOME)"; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cat > "$work/arrays.l" <<'LYR'
package TypedArrays

import Std.Core

func add3(a: in array[3, Float], b: in array[3, Float]): array[3, Float] {
  var r: array[3, Float] = [0.0f32, 0.0f32, 0.0f32]
  for i in 0 ..< 3 {
    r[i] = a[i] + b[i]
  }
  r
}

func dot3(a: in array[3, Float], b: in array[3, Float]): Float {
  var t = 0.0f32
  for i in 0 ..< 3 {
    t += a[i] * b[i]
  }
  t
}

func scaleInPlace(a: inout array[4, Int], k: in Int): Unit {
  for i in 0 ..< 4 {
    a[i] *= k
  }
}

func sum4(a: in array[4, Int]): Int {
  var t = 0
  for x in a {
    t = t + x
  }
  t
}

func main(): Int {
  val u: array[3, Float] = [1.0, 2.0, 3.0]
  val v: array[3, Float] = [4.0, 5.0, 6.0]
  val w = add3(u, v)
  var n: array[4, Int] = [1, 2, 3, 4]
  scaleInPlace(n, 3)
  println(toString(dot3(w, u)) + " " + toString(sum4(n)))
  0
}
LYR

"$LYRIC" build --target jvm "$work/arrays.l" -o "$work/arrays.jar"
got="$(java -jar "$work/arrays.jar" 2>&1 | grep -v '^Picked up JAVA_TOOL_OPTIONS' || true)"
[ "$got" = "46 30" ] || { echo "FAIL: expected '46 30', got '$got'"; exit 1; }

mkdir "$work/classes"
(cd "$work/classes" && unzip -q ../arrays.jar)
"$JAVAP" -c -p "$work/classes/TypedArrays.class" > "$work/disasm.txt"

method_body() {
  awk -v sig="$1" 'index($0, sig) { on = 1; print; next } on && /^$/ { exit } on { print }' "$work/disasm.txt"
}
box_re="java/lang/(Integer|Long|Float|Double|Boolean|Byte|Short|Character)\.valueOf|java/util/ArrayList"
fail=0
for sig in \
  "float[] add3(float[], float[])" \
  "float dot3(float[], float[])" \
  "sum4(int[])"; do
  body="$(method_body "$sig")"
  if [ -z "$body" ]; then
    echo "FAIL: no method '$sig' (is the array still lowered to a typed Java array?)"
    fail=1
    continue
  fi
  if grep -Eq "$box_re" <<<"$body"; then
    echo "FAIL: '$sig' boxes or uses ArrayList:"
    grep -E "$box_re" <<<"$body" | sed 's/^/  /'
    fail=1
  fi
done
scale="$(grep -E 'scaleInPlace\(' "$work/disasm.txt" | head -1)"
grep -q 'int\[\]' <<<"$scale" || { echo "FAIL: scaleInPlace does not take int[]: $scale"; fail=1; }
[ "$fail" = 0 ] || exit 1
echo "JVM typed arrays: numeric array[N, T] code boxes nothing"
