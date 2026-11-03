#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# interface-embed-e2e.sh: a library build embeds its package interface
# (docs/70 §9.6, D327). Through the real CLI, on each target:
#   - a library of several declaration kinds embeds an interface that
#     `lyric interface dump` prints, with its hash;
#   - building the same library twice gives the same interface hash;
#   - an executable embeds no interface;
#   - a library with a `pub val` whose type is neither written nor a literal's
#     is T0223, against the declaration.
#
#   bash scripts/ci/interface-embed-e2e.sh [dotnet] [jvm]
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
lyric_bin="$(cd "$(dirname "$lyric_bin")" && pwd)/$(basename "$lyric_bin")"
targets=("$@")
[ ${#targets[@]} -gt 0 ] || targets=(dotnet)
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fail=0

artifact() {
  case "$1" in
    dotnet) echo "out/Lib.dll" ;;
    jvm) echo "out/Lib.jar" ;;
  esac
}

# project <name> <package kind: lib|exe>: a fresh project whose one package is `src/`.
project() {
  local dir="$work/$1"
  rm -rf "$dir"
  mkdir -p "$dir/src"
  cat > "$dir/lyric.toml" <<TOML
[package]
name = "Lib"
version = "0.1.0"

[project]
name = "Lib"
output = "single"
output_assembly = "Lib.dll"

[project.packages]
"Lib" = "src"
TOML
  echo "$dir"
}

build() {
  local dir="$1" target="$2"
  (cd "$dir" && "$lyric_bin" build --manifest lyric.toml --target "$target" -o "$(artifact "$target")")
}

for target in "${targets[@]}"; do
  dir="$(project "lib_$target")"
  cat > "$dir/src/lib.l" <<'LYRIC'
package Lib

pub record Point {
  x: Int
  y: Int = 0
}

pub union Shape {
  case Circle(radius: Int)
  case Empty
}

pub type Age = Int range 0 ..= 150

pub val Limit: Int = 100

pub func add(a: Int, b: Int): Int {
  a + b
}

func hidden(): Int {
  1
}
LYRIC
  if ! build "$dir" "$target" > "$work/log" 2>&1; then
    echo "FAIL [$target] the library build failed"; cat "$work/log"; fail=1; continue
  fi
  dump="$(cd "$dir" && "$lyric_bin" interface dump "$(artifact "$target")" 2>"$work/err")" || {
    echo "FAIL [$target] interface dump failed"; cat "$work/err"; fail=1; continue
  }
  ok=1
  for want in \
    "interface Lib (format 3)" \
    "pub record Lib::Point(x: Int, y: Int = <default>)" \
    "pub union case Lib::Shape::Circle(radius: Int)" \
    "pub distinct Lib::Age = Int range 0 ..= 150" \
    "pub val Lib::Limit: Int = 100" \
    "pub func Lib::add(Int,Int)(a: in Int, b: in Int): Int"; do
    if ! grep -qF -- "$want" <<<"$dump"; then
      echo "FAIL [$target] the dump lacks: $want"; ok=0
    fi
  done
  if grep -q "hidden" <<<"$dump"; then
    echo "FAIL [$target] a private function is in the interface"; ok=0
  fi
  [ "$ok" = 1 ] && echo "PASS [$target] the library embeds its interface" || { echo "$dump"; fail=1; }

  hash1="$(grep '^hash:' <<<"$dump")"
  build "$dir" "$target" > /dev/null 2>&1
  hash2="$(cd "$dir" && "$lyric_bin" interface dump "$(artifact "$target")" 2>/dev/null | grep '^hash:')"
  if [ -n "$hash1" ] && [ "$hash1" = "$hash2" ]; then
    echo "PASS [$target] the interface hash is stable across builds"
  else
    echo "FAIL [$target] the interface hash changed: '$hash1' vs '$hash2'"; fail=1
  fi

  edir="$(project "exe_$target")"
  cat > "$edir/src/main.l" <<'LYRIC'
package Lib

pub val Computed = 1 + 2

func main(): Int {
  0
}
LYRIC
  if ! build "$edir" "$target" > "$work/log" 2>&1; then
    echo "FAIL [$target] the executable build failed"; cat "$work/log"; fail=1; continue
  fi
  if (cd "$edir" && "$lyric_bin" interface dump "$(artifact "$target")") > "$work/log" 2>&1; then
    echo "FAIL [$target] an executable embeds an interface"; fail=1
  elif grep -q "no Lyric.Interface" "$work/log"; then
    echo "PASS [$target] an executable embeds no interface"
  else
    echo "FAIL [$target] unexpected dump output for an executable"; cat "$work/log"; fail=1
  fi

  bdir="$(project "bad_$target")"
  cat > "$bdir/src/lib.l" <<'LYRIC'
package Lib

pub val Computed = 1 + 2
LYRIC
  if build "$bdir" "$target" > "$work/log" 2>&1; then
    echo "FAIL [$target] a library with an unrecordable pub val built"; fail=1
  elif grep -q "T0223" "$work/log" && grep -q "Lib::Computed" "$work/log"; then
    echo "PASS [$target] an unrecordable declaration is T0223"
  else
    echo "FAIL [$target] expected T0223 naming Lib::Computed"; cat "$work/log"; fail=1
  fi
done

exit "$fail"
