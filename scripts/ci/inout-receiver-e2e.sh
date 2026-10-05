#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# inout-receiver-e2e.sh: a method with an `inout` receiver (`self: inout T`,
# #8179) declared in one package and called from another.  A two-package
# project, and the same application against the library built on its own (a
# restored dependency, read through its contract metadata):
#   - a record-body method and a dot-named function with an `inout` receiver,
#     called with method syntax and through the type;
#   - a generic record's `inout` method;
#   - generic functions of the library with an `inout` parameter (native
#     instantiates another package's generics itself and passed the value,
#     not the address, before #8179);
#   - an application with its own `Box` (with or without its own `set`)
#     calling the library's generic `Box[T].set`: the call, and the `Box`
#     its specialised body constructs, are the library's.
#
#   bash scripts/ci/inout-receiver-e2e.sh [dotnet] [jvm] [native]
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

lib_src='package IrLib

pub record Pt {
  x: Int
  y: Int

  func reset(self: inout Pt): Unit {
    self = Pt(x = 0, y = 0)
  }

  func moved(self: inout Pt, d: in Int): Unit {
    self = Pt(x = x + d, y = y + d)
  }
}

pub func Pt.scaled(self: inout Pt, k: in Int): Unit {
  self = Pt(x = self.x * k, y = self.y * k)
}

pub record Box[T] {
  v: T

  func set(self: inout Box[T], v: in T): Unit {
    self = Box(v = v)
  }
}

pub func putBox[T](q: inout Box[T], v: in T): Unit {
  q = Box(v = v)
}

pub func countUp[T](n: inout Int, tag: in T): Unit {
  n = n + 1
}'

app_src='package IrApp

import Std.Core
import IrLib

func main(): Int {
  var p = Pt(x = 5, y = 6)
  p.moved(1)
  p.scaled(2)
  Pt.scaled(p, 2)
  val beforeReset = p.x * 10 + p.y
  Pt.moved(p, 1)
  val afterMove = p.x * 10 + p.y
  p.reset()
  var b = Box(v = 1)
  b.set(40)
  putBox(b, b.v + 2)
  var n = 1
  countUp(n, "t")
  println(toString(beforeReset) + " " + toString(afterMove) + " " + toString(p.x + p.y) + " " + toString(b.v) + " " + toString(n))
  0
}'

mkdir -p "$work/proj/src" "$work/restored/lib/src" "$work/restored/app/src"
cat > "$work/proj/lyric.toml" <<'TOML'
[package]
name = "IrApp"
version = "0.1.0"
[project]
name = "IrApp"
[project.packages]
"IrLib" = "src/lib.l"
"IrApp" = "src/app.l"
TOML
printf '%s\n' "$lib_src" > "$work/proj/src/lib.l"
printf '%s\n' "$app_src" > "$work/proj/src/app.l"
cat > "$work/restored/lib/lyric.toml" <<'TOML'
[package]
name = "Ir.Lib"
version = "0.1.0"
[project]
name = "Ir.Lib"
output = "single"
output_assembly = "IrLib.dll"
[project.packages]
"IrLib" = "src/lib.l"
TOML
cat > "$work/restored/app/lyric.toml" <<'TOML'
[package]
name = "Ir.App"
version = "0.1.0"
[project]
name = "Ir.App"
output = "single"
output_assembly = "IrApp.dll"
[project.packages]
"IrApp" = "src/app.l"
[dependencies]
"Ir.Lib" = { path = "../lib" }
TOML
printf '%s\n' "$lib_src" > "$work/restored/lib/src/lib.l"
printf '%s\n' "$app_src" > "$work/restored/app/src/app.l"

# p: (5,6) -> moved 1 (6,7) -> scaled 2 (12,14) -> scaled 2 (24,28) = 268;
# moved 1 (25,29) = 279; reset = 0; b: 40 then 42; n: 2.
clash_lib='package XLib

pub record Box[T] {
  v: T

  func set(self: inout Box[T], v: in T): Unit {
    self = Box(v = v)
  }
}'

write_clash() { # $1=dir $2=app source
  mkdir -p "$work/$1/src"
  cat > "$work/$1/lyric.toml" <<'TOML'
[package]
name = "XApp"
version = "0.1.0"
[project]
name = "XApp"
[project.packages]
"XLib" = "src/lib.l"
"XApp" = "src/app.l"
TOML
  printf '%s\n' "$clash_lib" > "$work/$1/src/lib.l"
  printf '%s\n' "$2" > "$work/$1/src/app.l"
}

write_clash clash_method 'package XApp

import Std.Core
import XLib as XL

record Box {
  w: Int

  func set(self: inout Box, w: in Int): Unit {
    self = Box(w = w * 100)
  }
}

func main(): Int {
  var b = XL.Box(v = 1)
  b.set(9)
  var mine = Box(w = 1)
  mine.set(2)
  println(toString(b.v) + " " + toString(mine.w))
  0
}'
write_clash clash_type 'package XApp

import Std.Core
import XLib as XL

record Box {
  w: Int
}

func main(): Int {
  var b = XL.Box(v = 1)
  b.set(9)
  XL.Box.set(b, b.v + 1)
  val mine = Box(w = 1)
  println(toString(b.v) + " " + toString(mine.w))
  0
}'
write_clash clash_string 'package XApp

import Std.Core
import XLib as XL

record Box {
  w: Int

  func set(self: inout Box, w: in Int): Unit {
    self = Box(w = w * 100)
  }
}

func main(): Int {
  var b = XL.Box(v = "a")
  b.set("z")
  println(b.v)
  0
}'

want="268 279 0 42 2"
fail=0
for t in "${targets[@]}"; do
  out="$("$lyric_bin" run --manifest "$work/proj/lyric.toml" --target "$t" 2>&1 | grep -v '^Picked up JAVA_TOOL_OPTIONS')"
  if [ "$(printf '%s\n' "$out" | tail -n 1)" != "$want" ]; then
    echo "FAIL ($t): calls into a sibling package's \`inout\` receivers should print '$want'; got:"
    printf '%s\n' "$out" | tail -n 5 | sed 's/^/  /'
    fail=1
  fi
  "$lyric_bin" build --manifest "$work/restored/lib/lyric.toml" --target "$t" >/dev/null 2>&1
  out="$("$lyric_bin" run --manifest "$work/restored/app/lyric.toml" --target "$t" 2>&1 | grep -v '^Picked up JAVA_TOOL_OPTIONS')"
  if [ "$(printf '%s\n' "$out" | tail -n 1)" != "$want" ]; then
    echo "FAIL ($t): calls into a dependency's \`inout\` receivers should print '$want'; got:"
    printf '%s\n' "$out" | tail -n 5 | sed 's/^/  /'
    fail=1
  fi
  for clash in "clash_method:9 200" "clash_type:10 1" "clash_string:z"; do
    name="${clash%%:*}"
    cwant="${clash#*:}"
    out="$("$lyric_bin" run --manifest "$work/$name/lyric.toml" --target "$t" 2>&1 | grep -v '^Picked up JAVA_TOOL_OPTIONS')"
    if [ "$(printf '%s\n' "$out" | tail -n 1)" != "$cwant" ]; then
      echo "FAIL ($t): '$name' should call the library's generic \`Box[T].set\` and print '$cwant'; got:"
      printf '%s\n' "$out" | tail -n 5 | sed 's/^/  /'
      fail=1
    fi
  done
done
[ "$fail" = 0 ] || exit 1
echo "inout receivers: called from another package, from a dependency, and past a same-named type of the caller, on: ${targets[*]}"
