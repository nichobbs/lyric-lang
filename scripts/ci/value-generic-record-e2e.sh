#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# value-generic-record-e2e.sh: a value-generic record (D169) is usable only in
# its own package for now (#8150).  A two-package project:
#   - positive: the library uses its own `Vec[N: Nat]` behind a public
#     function, which the application calls; it builds and prints the sum;
#   - negative: the application names the library's record, which is T0164.
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
    for x in self.items {
      t = t + x
    }
    t
  }
}

pub func sumOfThree(a: in Int, b: in Int, c: in Int): Int {
  val xs: array[3, Int] = [a, b, c]
  Vec(items = xs).total()
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
  println(toString(Vec(items = xs).total()))
  0
}'

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
  out="$("$lyric_bin" build --manifest "$work/foreign/lyric.toml" --target "$t" 2>&1)"
  code=$?
  if [ "$code" = 0 ] || ! grep -q 'T0164' <<<"$out"; then
    echo "FAIL ($t): naming another package's value-generic record should be T0164; exit $code:"
    printf '%s\n' "$out" | tail -n 5 | sed 's/^/  /'
    fail=1
  fi
done
[ "$fail" = 0 ] || exit 1
echo "value-generic records: package-local use builds and runs, a foreign use is T0164, and T0060/T0043/T0163 are reported, on: ${targets[*]}"
