#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# value-generic-record-e2e.sh: a value-generic record (D169) is usable from
# any package (D173).  A two-package project:
#   - the library uses its own `Vec[N: Nat]` behind a public function, which
#     the application calls; it builds and prints the sum;
#   - the application builds the library's record at two lengths, calls its
#     methods (one calling another), passes an instance to a library function
#     taking `Vec[3]`, takes one back from a function returning `Vec[2]`, and
#     zero fills one from its type; it builds and prints each result;
#   - the same application against the library as a separately built
#     dependency, read through its contract metadata.
# And single-file programs every target rejects: an instance where another
# length is expected (T0060), two fields giving one length different values
# (T0043), and a type where a length is expected (T0163).
#
#   bash scripts/ci/value-generic-record-e2e.sh [dotnet] [jvm] [native]
# LYRIC_BIN overrides the binary (default: the AOT build for BUILD_CONFIG).
# ---------------------------------------------------------------------------
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
BUILD_CONFIG="${BUILD_CONFIG:-Debug}"
lyric_bin="${LYRIC_BIN:-bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric}"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::lyric binary not found at $lyric_bin" >&2
  exit 1
fi
targets=("$@")
[ ${#targets[@]} -gt 0 ] || targets=(dotnet jvm native)
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

write_project() { # $1=dir $2=app source
  mkdir -p "$work/$1/src"
  cat > "$work/$1/lyric.toml" <<'TOML'
[package]
name = "VgApp"
version = "0.1.0"
[project]
name = "VgApp"
[project.packages]
"VgLib" = "src/lib.l"
"VgApp" = "src/app.l"
TOML
  cat > "$work/$1/src/lib.l" <<'EOF'
package VgLib

pub record Vec[N: Nat] {
  var items: array[N, Int]

  func total(self: in Vec[N]): Int {
    var t = 0
    for x in items {
      t = t + x
    }
    t
  }

  func size(self: in Vec[N]): Int = N

  func doubled(self: in Vec[N]): Int = total() * 2
}

pub func sumOfThree(a: in Int, b: in Int, c: in Int): Int {
  val xs: array[3, Int] = [a, b, c]
  Vec(items = xs).total()
}

pub func sum3(v: in Vec[3]): Int = v.total()

pub func makePair(a: in Int, b: in Int): Vec[2] {
  val xs: array[2, Int] = [a, b]
  Vec(items = xs)
}
EOF
  printf '%s\n' "$2" > "$work/$1/src/app.l"
}

write_project ok 'package VgApp

import Std.Core
import VgLib

func main(): Int {
  println(toString(sumOfThree(1, 2, 3)))
  0
}'
write_project foreign 'package VgApp

import Std.Core
import VgLib

func main(): Int {
  val xs: array[2, Int] = [4, 5]
  val v = Vec(items = xs)
  val ys: array[3, Int] = [1, 2, 3]
  val p = makePair(7, 8)
  val z: Vec[4] = Vec()
  println(toString(v.total()) + " " + toString(v.doubled()) + " " + toString(Vec.size(v)))
  println(toString(sum3(Vec(items = ys))) + " " + toString(p.total()) + " " + toString(z.size() + z.total()))
  0
}'

# The library as its own project, and the application depending on it.
mkdir -p "$work/restored/lib/src" "$work/restored/app/src"
cat > "$work/restored/lib/lyric.toml" <<'TOML'
[package]
name = "Vg.Lib"
version = "0.1.0"
[project]
name = "Vg.Lib"
output = "single"
output_assembly = "VgLib.dll"
[project.packages]
"VgLib" = "src/lib.l"
TOML
cp "$work/foreign/src/lib.l" "$work/restored/lib/src/lib.l"
cat > "$work/restored/app/lyric.toml" <<'TOML'
[package]
name = "Vg.App"
version = "0.1.0"
[project]
name = "Vg.App"
output = "single"
output_assembly = "VgApp.dll"
[project.packages]
"VgApp" = "src/app.l"
[dependencies]
"Vg.Lib" = { path = "../lib" }
TOML
cp "$work/foreign/src/app.l" "$work/restored/app/src/app.l"

write_neg() { # $1=name $2=program body after the record
  cat > "$work/$1.l" <<EOF
package Neg

import Std.Core

record Buf[N: Nat] {
  var data: array[N, Int]
  var spare: array[N, Int]
}

$2
EOF
}
write_neg mismatch 'func main(): Int {
  val a: array[3, Int] = [1, 2, 3]
  val b: Buf[4] = Buf(data = a)
  0
}'
write_neg conflict 'func main(): Int {
  val a: array[3, Int] = [1, 2, 3]
  val c: array[2, Int] = [1, 2]
  val b = Buf(data = a, spare = c)
  0
}'
write_neg kind 'func f(b: in Buf[String]): Int = 0

func main(): Int = 0'

fail=0
for t in "${targets[@]}"; do
  for neg in mismatch:T0060 conflict:T0043 kind:T0163; do
    name="${neg%%:*}"
    want="${neg##*:}"
    out="$("$lyric_bin" build --target "$t" "$work/$name.l" 2>&1)"
    rc=$?
    if [ "$rc" = 0 ] || ! grep -q "$want" <<<"$out"; then
      echo "FAIL ($t): '$name' should be rejected with $want; exit $rc:"
      printf '%s\n' "$out" | tail -n 5 | sed 's/^/  /'
      fail=1
    fi
  done
  out="$("$lyric_bin" run --manifest "$work/ok/lyric.toml" --target "$t" 2>&1 | grep -v '^Picked up JAVA_TOOL_OPTIONS')"
  if [ "$(printf '%s\n' "$out" | tail -n 1)" != "6" ]; then
    echo "FAIL ($t): the library's own use of its value-generic record should print 6; got:"
    printf '%s\n' "$out" | tail -n 5 | sed 's/^/  /'
    fail=1
  fi
  out="$("$lyric_bin" run --manifest "$work/foreign/lyric.toml" --target "$t" 2>&1 | grep -v '^Picked up JAVA_TOOL_OPTIONS')"
  if [ "$(printf '%s\n' "$out" | tail -n 2 | tr '\n' '|')" != "9 18 2|6 15 4|" ]; then
    echo "FAIL ($t): using the library's value-generic record from the application should print '9 18 2' and '6 15 4'; got:"
    printf '%s\n' "$out" | tail -n 5 | sed 's/^/  /'
    fail=1
  fi
  "$lyric_bin" build --manifest "$work/restored/lib/lyric.toml" >/dev/null 2>&1
  out="$("$lyric_bin" run --manifest "$work/restored/app/lyric.toml" --target "$t" 2>&1 | grep -v '^Picked up JAVA_TOOL_OPTIONS')"
  if [ "$(printf '%s\n' "$out" | tail -n 2 | tr '\n' '|')" != "9 18 2|6 15 4|" ]; then
    echo "FAIL ($t): using the value-generic record of a dependency built on its own should print '9 18 2' and '6 15 4'; got:"
    printf '%s\n' "$out" | tail -n 5 | sed 's/^/  /'
    fail=1
  fi
done
[ "$fail" = 0 ] || exit 1
echo "value-generic records: used in their own package, from another and from a dependency, and T0060/T0043/T0163 are reported, on: ${targets[*]}"
