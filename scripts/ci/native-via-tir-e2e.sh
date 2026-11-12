#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# native-via-tir-e2e.sh - `lyric build --target native --via-tir` end to end
# (docs/70 phase 4a, D520): the functions TIR covers are lowered from TIR, the
# rest stay on the AST path, and the program prints what the AST path's does.
#
# Builds scripts/ci/native-via-tir/scalars.l twice (plain and --via-tir), runs
# both, requires identical output, and requires the via-TIR build's census to
# report every function lowered from TIR (a fallback is a regression of the lowering,
# printed with its reason).
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

grep -q '^native via-TIR: 7 of 7 functions lowered from TIR' "$work/census.txt" || {
  echo "::error::expected every function of scalars.l to be lowered from TIR"
  exit 1
}
if grep -q '^  fallback:' "$work/census.txt"; then
  echo "::error::scalars.l has a TIR fallback"
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

# By-value records (docs/70 phase 4a): construction, field reads, nested records and `.copy`
# lowered from TIR, the same comparison.  No ARC is involved, so there is no sanitizer stage.
recsrc=scripts/ci/native-via-tir/records.l
"$lyric_bin" build --target native "$recsrc" -o "$work/r_ast" >/dev/null
"$lyric_bin" build --target native --via-tir "$recsrc" -o "$work/r_tir" 2> "$work/r_census.txt" >/dev/null
cat "$work/r_census.txt"
"$work/r_ast" > "$work/r_ast.out"
"$work/r_tir" > "$work/r_tir.out"
diff -u "$work/r_ast.out" "$work/r_tir.out"
printf '7\n13\n4\n3\n15\n3\n' | diff -u - "$work/r_tir.out"
grep -q '^native via-TIR: 6 of 6 functions lowered from TIR' "$work/r_census.txt" || {
  echo "::error::expected every function of records.l to be lowered from TIR"
  exit 1
}

# Heap records (docs/70 phase 4a): allocation with a destructor, owned reference fields and `.copy`
# as a new object, lowered from TIR, then the same IR under AddressSanitizer.
hsrc=scripts/ci/native-via-tir/heaprecords.l
"$lyric_bin" build --target native "$hsrc" -o "$work/h_ast" >/dev/null
LYRIC_KEEP_LL=1 "$lyric_bin" build --target native --via-tir "$hsrc" -o "$work/h_tir" 2> "$work/h_census.txt" >/dev/null
cat "$work/h_census.txt"
"$work/h_ast" > "$work/h_ast.out"
"$work/h_tir" > "$work/h_tir.out"
diff -u "$work/h_ast.out" "$work/h_tir.out"
printf 'hi ann\n31\nann\n30\nann/core\nann/ops\nann/core\n' | diff -u - "$work/h_tir.out"
grep -q '^native via-TIR: 6 of 6 functions lowered from TIR' "$work/h_census.txt" || {
  echo "::error::expected every function of heaprecords.l to be lowered from TIR"
  exit 1
}
clang -O1 -g -fsanitize=address -Wno-override-module "$work/h_tir.ll" lyric-rt/build-asan-tir/lyric_rt.a -lm -lpthread -ldl -o "$work/h_asan"
"$work/h_asan" > "$work/h_asan.out"
diff -u "$work/h_tir.out" "$work/h_asan.out"
echo "heap records under AddressSanitizer: clean"


# Unions (docs/70 phase 4a): an inline tagged value and a heap object with reference payloads,
# built and matched from TIR, then the same IR under AddressSanitizer.
usrc=scripts/ci/native-via-tir/unions.l
"$lyric_bin" build --target native "$usrc" -o "$work/u_ast" >/dev/null
LYRIC_KEEP_LL=1 "$lyric_bin" build --target native --via-tir "$usrc" -o "$work/u_tir" 2> "$work/u_census.txt" >/dev/null
cat "$work/u_census.txt"
"$work/u_ast" > "$work/u_ast.out"
"$work/u_tir" > "$work/u_tir.out"
diff -u "$work/u_ast.out" "$work/u_tir.out"
printf '12\n15\n0\ntrue\nfalse\nhello\nab,ab\n-\n' | diff -u - "$work/u_tir.out"
grep -q '^native via-TIR: 7 of 7 functions lowered from TIR' "$work/u_census.txt" || {
  echo "::error::expected every function of unions.l to be lowered from TIR"
  exit 1
}
clang -O1 -g -fsanitize=address -Wno-override-module "$work/u_tir.ll" lyric-rt/build-asan-tir/lyric_rt.a -lm -lpthread -ldl -o "$work/u_asan"
"$work/u_asan" > "$work/u_asan.out"
diff -u "$work/u_tir.out" "$work/u_asan.out"
echo "unions under AddressSanitizer: clean"

echo "native-via-tir-e2e: ok"
