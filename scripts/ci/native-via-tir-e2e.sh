#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# native-via-tir-e2e.sh - `lyric build --target native --via-tir` end to end
# (docs/70 phase 4a, D520): the functions TIR covers are lowered from TIR, the
# rest stay on the AST path, and the program prints what the AST path's does.
#
# Builds scripts/ci/native-via-tir/scalars.l twice (plain and --via-tir), runs
# both, requires identical output, and requires the via-TIR build's census to
# report the six scalar functions lowered from TIR with `main` the one fallback
# (any other fallback is a regression of the lowering, printed with its reason).
#
# Usage: LYRIC_BIN=<lyric> bash scripts/ci/native-via-tir-e2e.sh
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

lyric_bin="${LYRIC_BIN:-./bin/lyric}"
work="$(mktemp -d "${TMPDIR:-/tmp}/via-tir.XXXXXX")"
trap 'rm -rf "$work"' EXIT
src=scripts/ci/native-via-tir/scalars.l

"$lyric_bin" build --target native "$src" -o "$work/ast" >/dev/null
"$lyric_bin" build --target native --via-tir "$src" -o "$work/tir" 2> "$work/census.txt" >/dev/null
cat "$work/census.txt"

"$work/ast" > "$work/ast.out"
"$work/tir" > "$work/tir.out"
diff -u "$work/ast.out" "$work/tir.out"
echo "outputs identical"

# `main` calls the console built-ins, which the slice does not lower yet: it is the one fallback.
grep -q '^native via-TIR: 6 of 7 functions lowered from TIR' "$work/census.txt" || {
  echo "::error::expected the six scalar functions of scalars.l to be lowered from TIR"
  exit 1
}
if [ "$(grep -c '^  fallback:' "$work/census.txt")" != "1" ]; then
  echo "::error::expected exactly one TIR fallback (main)"
  exit 1
fi
# The output the program is specified to print (not only equal to the AST path's).
printf '10\n20\n500\n0\n10\n7\n20\n5\nfalse\n' | diff -u - "$work/tir.out"

# Strings and ARC (docs/70 phase 4a): the same comparison for strings.l, then the TIR build's
# IR again under AddressSanitizer against an ASan-built runtime, so a leaked, double-released or
# prematurely released string fails the run.
strsrc=scripts/ci/native-via-tir/strings.l
"$lyric_bin" build --target native "$strsrc" -o "$work/s_ast" >/dev/null
LYRIC_KEEP_LL=1 "$lyric_bin" build --target native --via-tir "$strsrc" -o "$work/s_tir" 2> "$work/s_census.txt" >/dev/null
cat "$work/s_census.txt"
"$work/s_ast" > "$work/s_ast.out"
"$work/s_tir" > "$work/s_tir.out"
diff -u "$work/s_ast.out" "$work/s_tir.out"
printf 'Hello, world\nabab\nneg\nzero\npos:7\n01234\nfallback\nfirst\nshort\nabcd!\ntrue\nfalse\n4,3,1,\n' | diff -u - "$work/s_tir.out"
grep -q '^native via-TIR: 9 of 9 functions lowered from TIR' "$work/s_census.txt" || {
  echo "::error::expected every function of strings.l to be lowered from TIR"
  exit 1
}
[ -f "$work/s_tir.ll" ] || { echo "::error::LYRIC_KEEP_LL left no IR at $work/s_tir.ll"; exit 1; }
make -C lyric-rt BUILD=build-asan-tir CFLAGS="-O1 -g -std=c11 -fPIC -fsanitize=address" CC=clang build-asan-tir/lyric_rt.a
clang -O1 -g -fsanitize=address -Wno-override-module "$work/s_tir.ll" lyric-rt/build-asan-tir/lyric_rt.a -lm -lpthread -ldl -o "$work/s_asan"
"$work/s_asan" > "$work/s_asan.out"
diff -u "$work/s_tir.out" "$work/s_asan.out"
echo "strings under AddressSanitizer: clean"
echo "native-via-tir-e2e: ok"
