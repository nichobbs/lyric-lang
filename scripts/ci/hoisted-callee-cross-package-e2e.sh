#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# hoisted-callee-cross-package-e2e.sh: an indexed callee beside a `?` or an
# `await` argument, named from another package (#8279).  The `?` and `await`
# hoists leave a generic function under explicit type arguments
# (`firstOf[Int](...)`, which parses as an index of the function's name) in
# its call, and bind every other indexed callee before the arguments, so it
# runs first.  Two-package projects:
#   - an element of the library's `pub val` list of functions, used
#     unqualified, called with a `?` and with an `await` argument: the index
#     runs before the arguments (JVM and native; on dotnet a function value
#     read from a module-level `val` by index and bound ahead of a `?` is
#     invalid IL, tracked in #8283);
#   - the library's generic function under explicit type arguments, with an
#     array literal before a `?` and before an `await` argument, also against
#     the library built on its own (a restored dependency, read through its
#     contract metadata; a `pub val` with a computed initializer does not
#     cross that boundary, docs/45);
#   - the application's own generic function under explicit type arguments
#     while a package it does not import declares a `pub val` of the same
#     name: the name means the function, so it stays in its call.
#
#   bash scripts/ci/hoisted-callee-cross-package-e2e.sh [dotnet] [jvm] [native]
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

lib_src='package HcLib

import Std.Core
import Std.Collections

pub func add(a: in Int, b: in Int): Int = a + b

pub func mul(a: in Int, b: in Int): Int = a * b

pub val fns: List[(Int, Int) -> Int] = [add, mul]

pub func firstOf[T](xs: in array[2, T], v: in Int): T = xs[v]'

prelude='package HcApp

import Std.Core
import Std.Collections
import HcLib

val trace: List[String] = newList()

func note(s: in String, v: in Int): Int {
  trace.add(s)
  v
}

func ok(v: in Int): Result[Int, String] {
  trace.add("ok")
  Ok(value = v)
}

async func later(v: in Int): Int {
  trace.add("await")
  v
}

func since(start: in Int): String {
  var acc = ""
  var i = start
  while i < trace.count {
    val t: String = trace[i]
    acc = if acc.length == 0 { t } else { acc + "," + t }
    i = i + 1
  }
  acc
}

func show(r: in Result[Int, String]): String {
  match r {
    case Ok(v) -> toString(v)
    case Err(e) -> "err " + e
  }
}'

vals_src="$prelude"'

func viaTry(): Result[Int, String] {
  Ok(value = fns[note("idx", 1)](note("a", 3), ok(4)?))
}

async func viaAwait(): Int {
  fns[note("idx", 0)](note("a", 3), await later(4))
}

func main(): Int {
  val s0 = trace.count
  val a = show(viaTry())
  val ta = since(s0)
  val s1 = trace.count
  val b = await viaAwait()
  println(a + " " + ta + " " + toString(b) + " " + since(s1))
  0
}'

targs_src="$prelude"'

func typeArgsTry(): Result[Int, String] {
  Ok(value = firstOf[Int]([7, 8], ok(note("i", 1))?))
}

async func typeArgsAwait(): Int {
  firstOf[Int]([7, 8], await later(0))
}

func main(): Int {
  val s0 = trace.count
  val c = show(typeArgsTry())
  val d = await typeArgsAwait()
  println(c + " " + toString(d) + " " + since(s0))
  0
}'

write_project() { # $1=dir $2=app source
  mkdir -p "$work/$1/src"
  cat > "$work/$1/lyric.toml" <<'TOML'
[package]
name = "HcApp"
version = "0.1.0"
[project]
name = "HcApp"
[project.packages]
"HcLib" = "src/lib.l"
"HcApp" = "src/app.l"
TOML
  printf '%s\n' "$lib_src" > "$work/$1/src/lib.l"
  printf '%s\n' "$2" > "$work/$1/src/app.l"
}
write_project vals "$vals_src"
write_project targs "$targs_src"
mkdir -p "$work/unimported/src"
cat > "$work/unimported/lyric.toml" <<'TOML'
[package]
name = "HcOwn"
version = "0.1.0"
[project]
name = "HcOwn"
[project.packages]
"HcOther" = "src/other.l"
"HcOwn" = "src/app.l"
TOML
cat > "$work/unimported/src/other.l" <<'LYRIC'
package HcOther

pub val pick: Int = 1

pub func usePick(): Int = pick
LYRIC
cat > "$work/unimported/src/app.l" <<'LYRIC'
package HcOwn

import Std.Core

func ok(v: in Int): Result[Int, String] = Ok(value = v)

func pick[T](xs: in array[2, T], v: in Int): T = xs[v]

func viaTry(): Result[Int, String] {
  Ok(value = pick[Int]([7, 8], ok(1)?))
}

func main(): Int {
  match viaTry() {
    case Ok(v) -> println(toString(v))
    case Err(e) -> println("err " + e)
  }
  0
}
LYRIC
mkdir -p "$work/restored/lib/src" "$work/restored/app/src"
cat > "$work/restored/lib/lyric.toml" <<'TOML'
[package]
name = "Hc.Lib"
version = "0.1.0"
[project]
name = "Hc.Lib"
output = "single"
output_assembly = "HcLib.dll"
[project.packages]
"HcLib" = "src/lib.l"
TOML
cat > "$work/restored/app/lyric.toml" <<'TOML'
[package]
name = "Hc.App"
version = "0.1.0"
[project]
name = "Hc.App"
output = "single"
output_assembly = "HcApp.dll"
[project.packages]
"HcApp" = "src/app.l"
[dependencies]
"Hc.Lib" = { path = "../lib" }
TOML
printf '%s\n' "$lib_src" > "$work/restored/lib/src/lib.l"
printf '%s\n' "$targs_src" > "$work/restored/app/src/app.l"

check() { # $1=target $2=manifest $3=want $4=what
  local out
  out="$("$lyric_bin" run --manifest "$2" --target "$1" 2>&1 | grep -v '^Picked up JAVA_TOOL_OPTIONS')"
  if [ "$(printf '%s\n' "$out" | tail -n 1)" != "$3" ]; then
    echo "FAIL ($1): $4 should print '$3'; got:"
    printf '%s\n' "$out" | tail -n 5 | sed 's/^/  /'
    fail=1
  fi
}

# mul(3, 4) = 12 and add(3, 4) = 7, each index read before the arguments;
# firstOf picks 8 and then 7, its literal an array on every target.
vals_want="12 idx,a,ok 7 idx,a,await"
targs_want="8 7 i,ok,await"
fail=0
for t in "${targets[@]}"; do
  if [ "$t" != dotnet ]; then
    check "$t" "$work/vals/lyric.toml" "$vals_want" "an element of a sibling package's pub val list of functions"
  fi
  check "$t" "$work/targs/lyric.toml" "$targs_want" "a sibling package's generic function under explicit type arguments"
  check "$t" "$work/unimported/lyric.toml" "8" "the application's own generic function, beside an unimported package's pub val of its name,"
  "$lyric_bin" build --manifest "$work/restored/lib/lyric.toml" --target "$t" >/dev/null 2>&1
  check "$t" "$work/restored/app/lyric.toml" "$targs_want" "a dependency's generic function under explicit type arguments"
done
[ "$fail" = 0 ] || exit 1
echo "indexed callees beside ? and await, from another package and a dependency, on: ${targets[*]}"
