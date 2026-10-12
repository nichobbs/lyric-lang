#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# unit-lambda-cross-package-e2e.sh: a lambda whose checked type returns
# `Unit`, made inside another package's generic function, is the
# `Unit`-returning function its type is (#8299).  On dotnet such a function is
# an `Action`, and a value of it is read and invoked as one; an unannotated
# lambda in a generic `make[T]` was built as a `Func` in the specialisation the
# caller's package makes, and the call threw `InvalidCastException`.  A
# two-package project, and the same application against the library built on
# its own (a restored dependency):
#   - unannotated lambdas ending in a call of a `Unit` function and in
#     `List.add`, stored in a record's `(Int) -> Unit` and `() -> Unit` fields
#     by a generic `make[T]` and called from the application;
#   - a `Unit` lambda given to a generic record's `T` field and read back.
#
#   bash scripts/ci/unit-lambda-cross-package-e2e.sh [dotnet] [jvm]
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

lib_src='package UlLib

import Std.Core
import Std.Collections

pub record Inst {
  start: (Int) -> Unit
  close: () -> Unit
}

pub record Box[T] {
  pub v: T
}

pub func withIt(f: in () -> Unit): Unit {
  f()
}

pub func make[T](x: in T, log: in List[String]): Inst {
  val start = { n: Int ->
    withIt({ -> log.add("start") })
    log.add(toString(n))
  }
  val close = { -> log.add("close") }
  return Inst(start = start, close = close)
}

pub func boxed(log: in List[String]): Box[(Int) -> Unit] {
  Box(v = { a: Int -> log.add("boxed" + toString(a)) })
}'

app_src='package UlApp

import Std.Core
import Std.Collections
import UlLib

func main(): Int {
  val log: List[String] = newList()
  val i = make(5, log)
  i.start(1)
  i.close()
  val f = boxed(log).v
  f(2)
  val own = Box(v = { a: Int -> log.add("own" + toString(a)) })
  val g = own.v
  g(3)
  var acc = ""
  for s in log {
    acc = acc + s + " "
  }
  println(acc)
  0
}'

mkdir -p "$work/proj/src" "$work/restored/lib/src" "$work/restored/app/src"
cat > "$work/proj/lyric.toml" <<'TOML'
[package]
name = "UlApp"
version = "0.1.0"
[project]
name = "UlApp"
[project.packages]
"UlLib" = "src/lib.l"
"UlApp" = "src/app.l"
TOML
printf '%s\n' "$lib_src" > "$work/proj/src/lib.l"
printf '%s\n' "$app_src" > "$work/proj/src/app.l"
cat > "$work/restored/lib/lyric.toml" <<'TOML'
[package]
name = "Ul.Lib"
version = "0.1.0"
[project]
name = "Ul.Lib"
output = "single"
output_assembly = "UlLib.dll"
[project.packages]
"UlLib" = "src/lib.l"
TOML
cat > "$work/restored/app/lyric.toml" <<'TOML'
[package]
name = "Ul.App"
version = "0.1.0"
[project]
name = "Ul.App"
output = "single"
output_assembly = "UlApp.dll"
[project.packages]
"UlApp" = "src/app.l"
[dependencies]
"Ul.Lib" = { path = "../lib" }
TOML
printf '%s\n' "$lib_src" > "$work/restored/lib/src/lib.l"
printf '%s\n' "$app_src" > "$work/restored/app/src/app.l"

want="start 1 close boxed2 own3 "
fail=0
for t in "${targets[@]}"; do
  out="$("$lyric_bin" run --manifest "$work/proj/lyric.toml" --target "$t" 2>&1 | grep -v '^Picked up JAVA_TOOL_OPTIONS')"
  if [ "$(printf '%s\n' "$out" | tail -n 1)" != "$want" ]; then
    echo "FAIL ($t): a sibling package's Unit lambdas should print '$want'; got:"
    printf '%s\n' "$out" | tail -n 5 | sed 's/^/  /'
    fail=1
  fi
  "$lyric_bin" build --manifest "$work/restored/lib/lyric.toml" --target "$t" >/dev/null 2>&1
  out="$("$lyric_bin" run --manifest "$work/restored/app/lyric.toml" --target "$t" 2>&1 | grep -v '^Picked up JAVA_TOOL_OPTIONS')"
  if [ "$(printf '%s\n' "$out" | tail -n 1)" != "$want" ]; then
    echo "FAIL ($t): a dependency's Unit lambdas should print '$want'; got:"
    printf '%s\n' "$out" | tail -n 5 | sed 's/^/  /'
    fail=1
  fi
done
[ "$fail" = 0 ] || exit 1
echo "Unit lambdas: made in a sibling package's and a dependency's generic, and in a generic record field, on: ${targets[*]}"
