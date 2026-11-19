#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# generic-char-e2e.sh - a generic of one package that renders its type argument
# (`String + x`, `x.toString()`, `"${x}"`), called from another package with a
# `Char` and with an `Int` (#9131, D613).  `Char` and `Int` are both `i32` on
# `--target native` and its code generator keeps no static types, so the type
# argument has to be known when the generic is specialised; the program
# (examples/char-generics) must print the same text on every target.
#
#   LYRIC_BIN=<lyric> bash scripts/ci/generic-char-e2e.sh [target...]
#
# The targets default to all three.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

lyric_bin="${LYRIC_BIN:-./bin/lyric}"
if [ ! -x "$lyric_bin" ]; then
  BUILD_CONFIG="${BUILD_CONFIG:-Debug}"
  lyric_bin="bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/lyric"
fi
[ -x "$lyric_bin" ] || { echo "::error::lyric binary not found"; exit 1; }
case "$lyric_bin" in
  /*) ;;
  *) lyric_bin="$REPO_ROOT/$lyric_bin" ;;
esac
export LYRIC_STD_PATH="${LYRIC_STD_PATH:-$REPO_ROOT/lyric-stdlib/std}"

targets=("$@")
if [ "${#targets[@]}" -eq 0 ]; then
  targets=(dotnet jvm native)
fi

manifest="examples/char-generics/lyric.toml"
expected="examples/char-generics/expected.txt"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

for target in "${targets[@]}"; do
  echo "=== examples/char-generics (--target $target) ==="
  case "$target" in
    dotnet)
      "$lyric_bin" build --manifest "$manifest" --target dotnet -o "$work/app.dll"
      dotnet "$work/app.dll" > "$work/$target.out"
      ;;
    jvm)
      "$lyric_bin" build --manifest "$manifest" --target jvm -o "$work/app.jar"
      java -jar "$work/app.jar" > "$work/$target.out"
      ;;
    native)
      command -v clang >/dev/null || { echo "::error::clang not found on the runner"; exit 1; }
      if [ -z "${LYRIC_RT_PATH:-}" ]; then
        rt_build_dir="$work/lyric-rt-build"
        make -C lyric-rt BUILD="$rt_build_dir" >/dev/null
        export LYRIC_RT_PATH="$rt_build_dir/lyric_rt.a"
      fi
      "$lyric_bin" build --manifest "$manifest" --target native -o "$work/app"
      "$work/app" > "$work/$target.out"
      ;;
    *)
      echo "::error::unknown target $target"
      exit 1
      ;;
  esac
  if ! diff -u "$expected" "$work/$target.out"; then
    echo "::error::examples/char-generics printed different text on $target (#9131)"
    exit 1
  fi
done
echo "generic-char-e2e: ${targets[*]} print the expected text"
