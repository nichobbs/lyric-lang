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
#   - dot-named functions with an `in` receiver and an `inout`/`out`
#     argument (#8183), generic or not, with method syntax and through the
#     type and its package;
#   - an application with its own `Box` (with or without its own `set`)
#     calling the library's generic `Box[T].set`: the call, and the `Box`
#     its specialised body constructs, are the library's;
#   - the same for a generic dot-named function with an `in` receiver
#     (`Box.peek[T]`), with method syntax and through the type and its
#     package (`AL.Box.peek(g)`, `ALib.Box.peek(g)`), beside a caller's own
#     `Box.peek` and with none;
#   - a record-body method with an `inout` record, `out Int` and `inout
#     Instant` (a value type) parameter, and an `impl` method with an `inout
#     Self` parameter (#8210: the restored MemberRef encoded them by value,
#     `MissingMethodException`);
#   - dot-named functions of a primitive type (`Int.twice`, `Int.bump` with
#     an `inout` receiver, #8217), with method syntax and through the type;
#   - extensions (#8219): dot-named functions a package other than the one
#     declaring the type declares for it, `inout` and generic ones included,
#     called with method syntax, through the type and through their package,
#     beside a same-named extension of a package the caller does not import
#     and the type's own function of another arity, and from the body of a
#     generic function of the extending package specialised in the caller;
#   - the type's own function (a method in its body, or a dot-named function
#     of its package, from a sibling package or a dependency) beside a
#     same-named function of the caller, which T0170 warns about: both call
#     forms bind the type's own (D181); an extension with defaulted
#     parameters.
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

import Std.Time

pub record Pt {
  x: Int
  y: Int

  func reset(self: inout Pt): Unit {
    self = Pt(x = 0, y = 0)
  }

  func moved(self: inout Pt, d: in Int): Unit {
    self = Pt(x = x + d, y = y + d)
  }

  func total(self: in Pt): Int = x + y
}

pub func Pt.scaled(self: inout Pt, k: in Int): Unit {
  self = Pt(x = self.x * k, y = self.y * k)
}

pub func Pt.sum(self: in Pt): Int = self.x + self.y

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
}

pub record Acc {
  n: Int
}

pub func Acc.into(self: in Acc, x: inout Int, j: in Int): Unit {
  x = self.n + j
}

pub func Acc.setOut(self: in Acc, x: out Int, j: in Int): Int {
  x = self.n * j
  x + 1
}

pub func Box.take[T](self: in Box[T], x: inout T): Unit {
  x = self.v
}

pub record Holder {
  k: Int

  func setIt(self: in Holder, p: inout Pt): Unit {
    p = Pt(x = k, y = k)
  }

  func outIt(self: in Holder, z: out Int): Unit {
    z = k + 3
  }

  func stampIt(self: in Holder, i: inout Instant): Unit {
    i = fromEpochMillis(1000i64 * k.toLong())
  }
}

pub interface Absorb {
  func absorb(self: in Self, other: inout Self): Unit
}

impl Absorb for Acc {
  func absorb(self: in Self, other: inout Self): Unit {
    other = Acc(n = self.n + other.n)
  }
}

pub func Int.twice(self: in Int): Int = self * 2

pub func Int.bump(self: inout Int, d: in Int): Unit {
  self = self + d
}'

app_src='package IrApp

import Std.Core
import Std.Time
import IrLib

func Pt.sum(self: in Pt): Int = -9

func Pt.total(self: in Pt): Int = -8

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
  val a = Acc(n = 100)
  var y = 0
  a.into(y, 3)
  Acc.into(a, j = y + 1, x = y)
  var w = 0
  val r = a.setOut(w, 2) + 1
  IrLib.Acc.into(a, w, 5)
  var t = 0
  b.take(t)
  var s = ""
  Box.take(Box(v = "q"), s)
  val h = Holder(k = 7)
  var q = Pt(x = 0, y = 0)
  h.setIt(q)
  var z = 0
  h.outIt(z)
  var stamp = fromEpochMillis(0i64)
  h.stampIt(stamp)
  var acc = Acc(n = 1)
  Acc(n = 40).absorb(acc)
  var zi = 4
  zi.bump(3)
  Int.bump(zi, 1)
  val zz = zi.twice() + Int.twice(zi)
  println(toString(beforeReset) + " " + toString(afterMove) + " " + toString(p.x + p.y) + " " + toString(b.v) + " " + toString(n) + " " + toString(y) + " " + toString(r) + " " + toString(w) + " " + toString(t) + " " + s + " " + toString(q.x + q.y) + " " + toString(z) + " " + toString(instantEquals(stamp, fromEpochMillis(7000i64))) + " " + toString(acc.n) + " " + toString(zi) + " " + toString(zz) + " " + toString(q.sum()) + " " + toString(Pt.sum(q)) + " " + toString(q.total()) + " " + toString(Pt.total(q)))
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
# moved 1 (25,29) = 279; reset = 0; b: 40 then 42; n: 2.  A dot-named
# method's `inout`/`out` arguments (#8183): y = 103, then 100 + 104 = 204;
# w = 200, r = 202, then w = 105; t takes b.v (42); s takes "q".  The
# record-body and `impl` methods' `inout`/`out` arguments (#8210): q = (7, 7),
# z = 10, `stamp` = 7 s past the epoch, acc = 40 + 1.  A primitive's
# dot-named functions (#8217): zi = 4 + 3 + 1 = 8, zz = 16 + 16.  Pt's own
# `sum` and `total` over IrApp's same-named functions (D181): 14 four times.
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

peek_lib='package ALib

pub record Box[T] {
  v: T

  func get(self: in Box[T]): T = self.v
}

pub func Box.peek[T](self: in Box[T]): T = self.v'

write_peek() { # $1=dir $2=app source
  mkdir -p "$work/$1/src"
  cat > "$work/$1/lyric.toml" <<'TOML'
[package]
name = "PApp"
version = "0.1.0"
[project]
name = "PApp"
[project.packages]
"ALib" = "src/a.l"
"PApp" = "src/app.l"
TOML
  printf '%s\n' "$peek_lib" > "$work/$1/src/a.l"
  printf '%s\n' "$2" > "$work/$1/src/app.l"
}

write_peek peek_clash 'package PApp

import Std.Core
import ALib as AL

record Box {
  w: Int

  func get(self: in Box): Int = self.w + 1
}

func Box.peek(self: in Box): Int = self.w + 2

func main(): Int {
  val g = AL.Box(v = "s")
  val m = Box(w = 1)
  println(g.get() + " " + g.peek() + " " + AL.Box.peek(g) + " " + ALib.Box.peek(g) + " " + toString(m.get()) + " " + toString(m.peek()) + " " + toString(Box.peek(m)))
  0
}'
write_peek peek_noclash 'package PApp

import Std.Core
import ALib as AL

func main(): Int {
  val g = AL.Box(v = "s")
  println(g.peek() + " " + AL.Box.peek(g) + " " + ALib.Box.peek(g))
  0
}'

ext_a='package ExtA

pub record Bag {
  n: Int

  func get(self: in Bag): Int = self.n + 500
}

pub record Box[T] {
  v: T
}

pub func Bag.own(self: in Bag): Int = self.n + 1000'
ext_b='package ExtB

import ExtA

pub func Bag.extra(self: in Bag): Int = self.n + 2

pub func Bag.grow(self: inout Bag, by: in Int): Unit {
  self = Bag(n = self.n + by)
}

pub func Bag.own(self: in Bag, k: in Int): Int = self.n + k

pub func Bag.cfg(self: in Bag, a: in Int = 1, c: in Int = 2): Int = self.n * 100 + a * 10 + c

pub func Box.first[T](self: in Box[T]): T = self.v

pub func Int.twice(self: in Int): Int = self * 2

pub func extraTwice[T](b: in Bag, tag: in T): Int {
  var c = b
  c.grow(10)
  c.extra() + Bag.extra(c) + c.n.twice()
}'
ext_c='package ExtC

import ExtA

pub func Bag.extra(self: in Bag): Int = self.n + 3'
ext_app='package ExtApp

import Std.Core
import ExtA
import ExtB

func Bag.local(self: in Bag): Int = self.n * 10

func Bag.get(self: in Bag): Int = -1

func Bag.own(self: in Bag): Int = -2

func main(): Int {
  var b = Bag(n = 1)
  b.grow(4)
  Bag.grow(b, 1)
  val box = Box(v = "s")
  println(toString(b.extra()) + " " + toString(Bag.extra(b)) + " " + toString(ExtB.Bag.extra(b)) + " " + toString(b.local()) + " " + toString(Bag.local(b)) + " " + toString(b.n) + " " + box.first() + " " + toString(b.own()) + " " + toString(b.own(5)) + " " + toString(extraTwice(b, "t")) + " " + toString(b.get()) + " " + toString(Bag.get(b)) + " " + toString(Bag.own(b)) + " " + toString(b.cfg(c = 7)) + " " + toString(b.cfg()))
  0
}'
mkdir -p "$work/ext/src"
cat > "$work/ext/lyric.toml" <<'TOML'
[package]
name = "ExtApp"
version = "0.1.0"
[project]
name = "ExtApp"
[project.packages]
"ExtA" = "src/a.l"
"ExtB" = "src/b.l"
"ExtC" = "src/c.l"
"ExtApp" = "src/app.l"
TOML
printf '%s\n' "$ext_a" > "$work/ext/src/a.l"
printf '%s\n' "$ext_b" > "$work/ext/src/b.l"
printf '%s\n' "$ext_c" > "$work/ext/src/c.l"
printf '%s\n' "$ext_app" > "$work/ext/src/app.l"
# b: 1 + 4 + 1 = 6; ExtB's extra (not ExtC's, which ExtApp does not import)
# gives 8 three ways; the caller's own extension 60 two ways; ExtB's generic
# `first` gives "s"; ExtA's own `own()` 1006, ExtB's `own(5)` 11; ExtB's
# generic, specialised here, calls its own extensions: c.n = 16, 18 + 18 + 32.
# Bag's own `get` (506) and `own` (1006) over ExtApp's same-named functions,
# in both call forms; ExtB's `cfg` with its defaults: 617, 612.
ext_want="8 8 8 60 60 6 s 1006 11 68 506 506 1006 617 612"

want="268 279 0 42 2 204 202 105 42 q 14 10 true 41 8 32 14 14 14 14"
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
  out="$("$lyric_bin" run --manifest "$work/ext/lyric.toml" --target "$t" 2>&1 | grep -v '^Picked up JAVA_TOOL_OPTIONS')"
  if [ "$(printf '%s\n' "$out" | tail -n 1)" != "$ext_want" ]; then
    echo "FAIL ($t): extensions from another package should print '$ext_want'; got:"
    printf '%s\n' "$out" | tail -n 5 | sed 's/^/  /'
    fail=1
  fi
  for clash in "clash_method:9 200" "clash_type:10 1" "clash_string:z" "peek_clash:s s s s 2 3 3" "peek_noclash:s s s"; do
    name="${clash%%:*}"
    cwant="${clash#*:}"
    out="$("$lyric_bin" run --manifest "$work/$name/lyric.toml" --target "$t" 2>&1 | grep -v '^Picked up JAVA_TOOL_OPTIONS')"
    if [ "$(printf '%s\n' "$out" | tail -n 1)" != "$cwant" ]; then
      echo "FAIL ($t): '$name' should call the library's generic \`Box[T]\` functions and print '$cwant'; got:"
      printf '%s\n' "$out" | tail -n 5 | sed 's/^/  /'
      fail=1
    fi
  done
done
[ "$fail" = 0 ] || exit 1
echo "inout receivers and extensions: called from another package, from a dependency, and past a same-named type of the caller, on: ${targets[*]}"
