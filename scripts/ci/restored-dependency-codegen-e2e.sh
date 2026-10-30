#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# restored-dependency-codegen-e2e.sh: library constructs consumed from a
# restored dependency (the library built on its own, read through its contract
# metadata), and the same sources as sibling packages of one project:
#   - #8358: member access on an erased value (the result of a method-level
#     generic on a generic record);
#   - #7776: if/match branches of different library classes joined as a
#     library interface, `Result[I, String]` and `Option[I]`;
#   - #8337: `?` (`Result` and `Option`) in a generic library function
#     specialised in the consumer;
#   - #8329: a bare reference to a library function inside a generic library
#     body specialised in the consumer.
#
#   bash scripts/ci/restored-dependency-codegen-e2e.sh [dotnet] [jvm]
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
[ ${#targets[@]} -gt 0 ] || targets=(dotnet jvm)
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0

# mkcase NAME LIB_PACKAGE APP_PACKAGE: lib source on stdin file $work/NAME.lib,
# app source in $work/NAME.app.
mkcase() {
  local name="$1" lib="$2" app="$3"
  mkdir -p "$work/$name/lib/src" "$work/$name/app/src"
  cat > "$work/$name/lib/lyric.toml" <<TOML
[package]
name = "$lib"
version = "0.1.0"
[project]
name = "$lib"
output = "single"
output_assembly = "$lib.dll"
[project.packages]
"$lib" = "src/lib.l"
TOML
  cat > "$work/$name/app/lyric.toml" <<TOML
[package]
name = "$app"
version = "0.1.0"
[project]
name = "$app"
output = "single"
output_assembly = "$app.dll"
[project.packages]
"$app" = "src/app.l"
[dependencies]
"$lib" = { path = "../lib" }
TOML
  cp "$work/$name.lib" "$work/$name/lib/src/lib.l"
  cp "$work/$name.app" "$work/$name/app/src/app.l"
}

runcase() {
  local name="$1" want="$2" t out
  for t in "${targets[@]}"; do
    "$lyric_bin" build --manifest "$work/$name/lib/lyric.toml" --target "$t" >"$work/$name.build.log" 2>&1
    out="$("$lyric_bin" run --manifest "$work/$name/app/lyric.toml" --target "$t" 2>&1 | grep -v '^Picked up JAVA_TOOL_OPTIONS')"
    if [ "$(printf '%s\n' "$out" | tail -n 1)" != "$want" ]; then
      echo "FAIL ($t): '$name' should print '$want'; got:"
      printf '%s\n' "$out" | tail -n 6 | sed 's/^/  /'
      fail=1
    fi
  done
}

# mksib NAME LIB_PACKAGE APP_PACKAGE: the same sources as one project, the
# library a sibling package compiled from source.
mksib() {
  local name="$1" lib="$2" app="$3"
  mkdir -p "$work/$name/sib/src"
  cat > "$work/$name/sib/lyric.toml" <<TOML
[package]
name = "$app"
version = "0.1.0"
[project]
name = "$app"
[project.packages]
"$lib" = "src/lib.l"
"$app" = "src/app.l"
TOML
  cp "$work/$name.lib" "$work/$name/sib/src/lib.l"
  cp "$work/$name.app" "$work/$name/sib/src/app.l"
}

runsib() {
  local name="$1" want="$2" t out
  for t in "${targets[@]}"; do
    out="$("$lyric_bin" run --manifest "$work/$name/sib/lyric.toml" --target "$t" 2>&1 | grep -v '^Picked up JAVA_TOOL_OPTIONS')"
    if [ "$(printf '%s\n' "$out" | tail -n 1)" != "$want" ]; then
      echo "FAIL ($t): '$name' as a sibling package should print '$want'; got:"
      printf '%s\n' "$out" | tail -n 6 | sed 's/^/  /'
      fail=1
    fi
  done
}

# --- #8358: member access on an erased value ---------------------------------
cat > "$work/erased.lib" <<'L'
package ErLib

pub record Pt {
  x: Int
  y: Int
}

pub record Bx[T] {
  v: T

  func pick[U](self: in Bx[T], u: in U): U = u
}
L
cat > "$work/erased.app" <<'L'
package ErApp

import ErLib

func main(): Unit {
  val bx = Bx(v = 1)
  val a = bx.pick(Pt(x = 3, y = 4)).x
  val b = bx.pick(Pt(x = 5, y = 6)).y
  println(a + b)
}
L
mkcase erased ErLib ErApp
runcase erased "9"
mksib erased ErLib ErApp
runsib erased "9"

# --- #7776: branch joins of library classes -----------------------------------
cat > "$work/join.lib" <<'L'
package JnLib

pub interface Greeter {
  func greet(self: in Greeter): String
}

pub record En { n: String }
pub record Fr { n: String }

impl Greeter for En {
  func greet(self: in En): String = "hi " + self.n
}

impl Greeter for Fr {
  func greet(self: in Fr): String = "salut " + self.n
}
L
cat > "$work/join.app" <<'L'
package JnApp

import JnLib

record Holder { g: Greeter }

func pick(c: in Bool): Greeter {
  if c { En(n = "a") } else { Fr(n = "a") }
}

func pickR(c: in Bool): Result[Greeter, String] {
  if c { Ok(value = En(n = "b")) } else { Ok(value = Fr(n = "b")) }
}

func pickO(c: in Bool): Option[Greeter] {
  if c { Some(value = En(n = "c")) } else { Some(value = Fr(n = "c")) }
}

func useG(g: in Greeter): String = g.greet()

func main(): Unit {
  val bound: Greeter = if false { En(n = "d") } else { Fr(n = "d") }
  var assigned: Greeter = En(n = "e")
  assigned = if false { En(n = "e") } else { Fr(n = "e") }
  val h = Holder(g = if true { En(n = "f") } else { Fr(n = "f") })
  val r = match pickR(false) {
    case Ok(g) -> g.greet()
    case Err(e) -> e
  }
  val o = match pickO(true) {
    case Some(g) -> g.greet()
    case None -> "none"
  }
  println("${pick(true).greet()}|${r}|${o}|${useG(if true { En(n = "g") } else { Fr(n = "g") })}|${bound.greet()}|${assigned.greet()}|${h.g.greet()}")
}
L
mkcase join JnLib JnApp
runcase join "hi a|salut b|hi c|hi g|salut d|salut e|hi f"
mksib join JnLib JnApp
runsib join "hi a|salut b|hi c|hi g|salut d|salut e|hi f"

# --- #8337: `?` in a generic library function ---------------------------------
cat > "$work/try.lib" <<'L'
package TqLib

pub func chkF(k: in Int): Result[Int, String] {
  if k > 0 { Ok(value = k) } else { Err(error = "neg") }
}

pub func g2e[T](t: in T, k: in Int): Result[Int, String] {
  val v = chkF(k)?
  Ok(value = v + 1)
}
L
cat > "$work/try.app" <<'L'
package TqApp

import TqLib

func show(r: in Result[Int, String]): String {
  match r {
    case Ok(v) -> "ok ${v}"
    case Err(e) -> "err ${e}"
  }
}

func main(): Unit {
  println("${show(g2e("x", 3))} ${show(g2e("x", -1))}")
}
L
mkcase try TqLib TqApp
runcase try "ok 4 err neg"
mksib try TqLib TqApp
runsib try "ok 4 err neg"

cat > "$work/tryopt.lib" <<'L'
package ToLib

pub func firstOf(k: in Int): Option[Int] {
  if k > 0 { Some(value = k) } else { None }
}

pub func plus[T](t: in T, k: in Int): Option[Int] {
  val v = firstOf(k)?
  val w = firstOf(v - 1)?
  Some(value = v + w)
}
L
cat > "$work/tryopt.app" <<'L'
package ToApp

import ToLib

func show(o: in Option[Int]): String {
  match o {
    case Some(v) -> "some ${v}"
    case None -> "none"
  }
}

func main(): Unit {
  println("${show(plus("x", 3))} ${show(plus("x", 1))} ${show(plus("x", -2))}")
}
L
mkcase tryopt ToLib ToApp
runcase tryopt "some 5 none none"
mksib tryopt ToLib ToApp
runsib tryopt "some 5 none none"

# --- #8329: bare function reference in a generic library body -----------------
cat > "$work/fnref.lib" <<'L'
package FrLib

import Std.Collections

pub func ping(): Int = 1
pub func pong(): Int = 2

pub func mkHooks[T](x: in T): List[() -> Int] {
  val l: List[() -> Int] = newList()
  l.add(ping)
  l.add(pong)
  l
}
L
cat > "$work/fnref.app" <<'L'
package FrApp

import FrLib
import Std.Collections

func main(): Unit {
  val hs = mkHooks(1)
  var s = 0
  for h in hs { s = s + h() }
  println(s)
}
L
mkcase fnref FrLib FrApp
runcase fnref "3"
mksib fnref FrLib FrApp
runsib fnref "3"

[ "$fail" = 0 ] || exit 1
echo "restored-dependency codegen: erased member access, branch joins, \`?\` in generics, function values, on: ${targets[*]}"
