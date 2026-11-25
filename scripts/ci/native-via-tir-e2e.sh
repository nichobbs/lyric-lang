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
grep -q '^native via-TIR: 6 of 6 functions lowered from TIR' "$work/u_census.txt" || {
  echo "::error::expected every function of unions.l to be lowered from TIR"
  exit 1
}
clang -O1 -g -fsanitize=address -Wno-override-module "$work/u_tir.ll" lyric-rt/build-asan-tir/lyric_rt.a -lm -lpthread -ldl -o "$work/u_asan"
"$work/u_asan" > "$work/u_asan.out"
diff -u "$work/u_tir.out" "$work/u_asan.out"
echo "unions under AddressSanitizer: clean"

# Text (docs/70 phase 4a): interpolation, matching a String against literals, a Double literal
# pattern and string indexing from TIR, then the same IR under AddressSanitizer.
xsrc=scripts/ci/native-via-tir/text.l
"$lyric_bin" build --target native "$xsrc" -o "$work/x_ast" >/dev/null
LYRIC_KEEP_LL=1 "$lyric_bin" build --target native --via-tir "$xsrc" -o "$work/x_tir" 2> "$work/x_census.txt" >/dev/null
cat "$work/x_census.txt"
"$work/x_ast" > "$work/x_ast.out"
"$work/x_tir" > "$work/x_tir.out"
diff -u "$work/x_ast.out" "$work/x_tir.out"
printf 'n=7 s=q!\n2\n0\n0.5\n2.5\nz\n' | diff -u - "$work/x_tir.out"
grep -q '^native via-TIR: 5 of 5 functions lowered from TIR' "$work/x_census.txt" || {
  echo "::error::expected every function of text.l to be lowered from TIR"
  exit 1
}
clang -O1 -g -fsanitize=address -Wno-override-module "$work/x_tir.ll" lyric-rt/build-asan-tir/lyric_rt.a -lm -lpthread -ldl -o "$work/x_asan"
"$work/x_asan" > "$work/x_asan.out"
diff -u "$work/x_tir.out" "$work/x_asan.out"
echo "text under AddressSanitizer: clean"

# Enums (docs/70 phase 4a): an enum is its ordinal and a case pattern compares it.
esrc=scripts/ci/native-via-tir/enums.l
"$lyric_bin" build --target native "$esrc" -o "$work/e_ast" >/dev/null
"$lyric_bin" build --target native --via-tir "$esrc" -o "$work/e_tir" 2> "$work/e_census.txt" >/dev/null
cat "$work/e_census.txt"
"$work/e_ast" > "$work/e_ast.out"
"$work/e_tir" > "$work/e_tir.out"
diff -u "$work/e_ast.out" "$work/e_tir.out"
printf '10\n20\n10\n' | diff -u - "$work/e_tir.out"
grep -q '^native via-TIR: 3 of 3 functions lowered from TIR' "$work/e_census.txt" || {
  echo "::error::expected every function of enums.l to be lowered from TIR"
  exit 1
}

# Tuples (docs/70 phase 4a): construction, destructuring lets and tuple patterns, then the same
# IR under AddressSanitizer.
tsrc=scripts/ci/native-via-tir/tuples.l
"$lyric_bin" build --target native "$tsrc" -o "$work/t_ast" >/dev/null
LYRIC_KEEP_LL=1 "$lyric_bin" build --target native --via-tir "$tsrc" -o "$work/t_tir" 2> "$work/t_census.txt" >/dev/null
cat "$work/t_census.txt"
"$work/t_ast" > "$work/t_ast.out"
"$work/t_tir" > "$work/t_tir.out"
diff -u "$work/t_ast.out" "$work/t_tir.out"
printf 'n5=5\n4,3\nzero:n0\none\nn9/9\n123\n' | diff -u - "$work/t_tir.out"
grep -q '^native via-TIR: 6 of 6 functions lowered from TIR' "$work/t_census.txt" || {
  echo "::error::expected every function of tuples.l to be lowered from TIR"
  exit 1
}
clang -O1 -g -fsanitize=address -Wno-override-module "$work/t_tir.ll" lyric-rt/build-asan-tir/lyric_rt.a -lm -lpthread -ldl -o "$work/t_asan"
"$work/t_asan" > "$work/t_asan.out"
diff -u "$work/t_tir.out" "$work/t_asan.out"
echo "tuples under AddressSanitizer: clean"

# Closures (docs/70 phase 4a): function types, lambdas with reference and scalar captures and calls
# through function values, then the same IR under AddressSanitizer.
csrc=scripts/ci/native-via-tir/closures.l
"$lyric_bin" build --target native "$csrc" -o "$work/c_ast" >/dev/null
LYRIC_KEEP_LL=1 "$lyric_bin" build --target native --via-tir "$csrc" -o "$work/c_tir" 2> "$work/c_census.txt" >/dev/null
cat "$work/c_census.txt"
"$work/c_ast" > "$work/c_ast.out"
"$work/c_tir" > "$work/c_tir.out"
diff -u "$work/c_ast.out" "$work/c_tir.out"
printf '15\n21\nn=7\nhi there\n12\nran\np-x\n' | diff -u - "$work/c_tir.out"
grep -q '^native via-TIR: 7 of 7 functions lowered from TIR' "$work/c_census.txt" || {
  echo "::error::expected every function of closures.l to be lowered from TIR"
  exit 1
}
clang -O1 -g -fsanitize=address -Wno-override-module "$work/c_tir.ll" lyric-rt/build-asan-tir/lyric_rt.a -lm -lpthread -ldl -o "$work/c_asan"
"$work/c_asan" > "$work/c_asan.out"
diff -u "$work/c_tir.out" "$work/c_asan.out"
echo "closures under AddressSanitizer: clean"

# out/inout parameters and assignment to record fields (docs/70 phase 4a), then the same IR under
# AddressSanitizer.
isrc=scripts/ci/native-via-tir/inout.l
"$lyric_bin" build --target native "$isrc" -o "$work/i_ast" >/dev/null
LYRIC_KEEP_LL=1 "$lyric_bin" build --target native --via-tir "$isrc" -o "$work/i_tir" 2> "$work/i_census.txt" >/dev/null
cat "$work/i_census.txt"
"$work/i_ast" > "$work/i_ast.out"
"$work/i_tir" > "$work/i_tir.out"
diff -u "$work/i_ast.out" "$work/i_tir.out"
printf '3\n42\nbc\n4t!!\ndt!!\n' | diff -u - "$work/i_tir.out"
grep -q '^native via-TIR: 6 of 6 functions lowered from TIR' "$work/i_census.txt" || {
  echo "::error::expected every function of inout.l to be lowered from TIR"
  exit 1
}
clang -O1 -g -fsanitize=address -Wno-override-module "$work/i_tir.ll" lyric-rt/build-asan-tir/lyric_rt.a -lm -lpthread -ldl -o "$work/i_asan"
"$work/i_asan" > "$work/i_asan.out"
diff -u "$work/i_tir.out" "$work/i_asan.out"
echo "inout under AddressSanitizer: clean"

# Project builds (docs/70 phase 4a): every own package is lowered from TIR, including a call, a
# record, a union and a generic function (D533) that cross the package boundary.
pmf=scripts/ci/native-via-tir/project/lyric.toml
"$lyric_bin" build --manifest "$pmf" --target native -o "$work/p_ast" >/dev/null
"$lyric_bin" build --manifest "$pmf" --target native --via-tir -o "$work/p_tir" 2> "$work/p_census.txt" >/dev/null
cat "$work/p_census.txt"
"$work/p_ast" > "$work/p_ast.out"
"$work/p_tir" > "$work/p_tir.out"
diff -u "$work/p_ast.out" "$work/p_tir.out"
printf '35\n2\n42\n9\n' | diff -u - "$work/p_tir.out"
grep -q '^native via-TIR: 5 of 5 functions lowered from TIR' "$work/p_census.txt" || {
  echo "::error::expected every function of the two-package project to be lowered from TIR"
  exit 1
}

# Generic records, unions and functions (docs/70 phase 4a part 6): the bundle's TIR is monomorphised
# (`Lyric.Tir.Mono`, D500), the instances of `Box[Int]`, `Maybe[Int]` and `ident[Int]` take the layouts
# and names the AST path gives them, and every function lowers from TIR.  Output is the AST path's,
# and the build runs clean under AddressSanitizer.
fsrc=scripts/ci/native-via-tir/fallback.l
"$lyric_bin" build --target native "$fsrc" -o "$work/f_ast" >/dev/null
LYRIC_KEEP_LL=1 "$lyric_bin" build --target native --via-tir "$fsrc" -o "$work/f_tir" 2> "$work/f_census.txt" >/dev/null
cat "$work/f_census.txt"
"$work/f_ast" > "$work/f_ast.out"
"$work/f_tir" > "$work/f_tir.out"
diff -u "$work/f_ast.out" "$work/f_tir.out"
printf '42\n5\n7\n' | diff -u - "$work/f_tir.out"
grep -q '^native via-TIR: 5 of 5 functions lowered from TIR' "$work/f_census.txt" || {
  echo "::error::expected every function of fallback.l to be lowered from TIR"
  exit 1
}
if grep -q '^  fallback: ' "$work/f_census.txt"; then
  echo "::error::fallback.l has a TIR fallback"
  exit 1
fi
clang -O1 -g -fsanitize=address -Wno-override-module "$work/f_tir.ll" lyric-rt/build-asan-tir/lyric_rt.a -lm -lpthread -ldl -o "$work/f_asan"
"$work/f_asan" > "$work/f_asan.out"
diff -u "$work/f_tir.out" "$work/f_asan.out"
echo "generic fallback under AddressSanitizer: clean"

# Unit parameters, locals and arguments (docs/70 phase 4a, D536).
unsrc=scripts/ci/native-via-tir/unit.l
"$lyric_bin" build --target native "$unsrc" -o "$work/un_ast" >/dev/null
LYRIC_KEEP_LL=1 "$lyric_bin" build --target native --via-tir "$unsrc" -o "$work/un_tir" 2> "$work/un_census.txt" >/dev/null
cat "$work/un_census.txt"
"$work/un_ast" > "$work/un_ast.out"
"$work/un_tir" > "$work/un_tir.out"
diff -u "$work/un_ast.out" "$work/un_tir.out"
printf 'note 1\n2\nnote 7\n4\nnote 3\n1\n\nnote 2\n()\n' | diff -u - "$work/un_tir.out"
grep -q '^native via-TIR: 5 of 5 functions lowered from TIR' "$work/un_census.txt" || {
  echo "::error::expected every function of unit.l to be lowered from TIR"
  exit 1
}
if grep -q '^  fallback: ' "$work/un_census.txt"; then
  echo "::error::unit.l has a TIR fallback"
  exit 1
fi
clang -O1 -g -fsanitize=address -Wno-override-module "$work/un_tir.ll" lyric-rt/build-asan-tir/lyric_rt.a -lm -lpthread -ldl -o "$work/un_asan"
"$work/un_asan" > "$work/un_asan.out"
diff -u "$work/un_tir.out" "$work/un_asan.out"
echo "unit under AddressSanitizer: clean"

# Range-checked distinct types (docs/70 phase 4a, D538): `T.from`, derived arithmetic and a final
# out-of-range panic with the managed targets' message.
rgsrc=scripts/ci/native-via-tir/ranged.l
"$lyric_bin" build --target native "$rgsrc" -o "$work/rg_ast" >/dev/null
LYRIC_KEEP_LL=1 "$lyric_bin" build --target native --via-tir "$rgsrc" -o "$work/rg_tir" 2> "$work/rg_census.txt" >/dev/null
cat "$work/rg_census.txt"
"$work/rg_ast" > "$work/rg_ast.out" 2> "$work/rg_ast.err" || true
"$work/rg_tir" > "$work/rg_tir.out" 2> "$work/rg_tir.err" || true
diff -u "$work/rg_ast.out" "$work/rg_tir.out"
printf '1000\n750\n150\ntrue\ntrue\n5\n1\n5\nCents.tryFrom: value out of range [0, 1000]\nCents.tryFrom: value out of range [0, 1000]\nplain 7\n' | diff -u - "$work/rg_tir.out"
grep -q 'Cents.from: value out of range \[0, 1000\]' "$work/rg_tir.err" || { echo "::error::the TIR build did not panic with the range message"; cat "$work/rg_tir.err"; exit 1; }
grep -q 'Cents.from: value out of range \[0, 1000\]' "$work/rg_ast.err" || { echo "::error::the AST build did not panic with the range message"; exit 1; }
grep -q '^native via-TIR: 12 of 12 functions lowered from TIR' "$work/rg_census.txt" || {
  echo "::error::expected every function of ranged.l to be lowered from TIR"
  exit 1
}
clang -O1 -g -fsanitize=address -Wno-override-module "$work/rg_tir.ll" lyric-rt/build-asan-tir/lyric_rt.a -lm -lpthread -ldl -o "$work/rg_asan"
"$work/rg_asan" > "$work/rg_asan.out" 2> /dev/null || true
diff -u "$work/rg_tir.out" "$work/rg_asan.out"
echo "ranged distinct types under AddressSanitizer: clean"

# `nativeAddrOf` of a String local and `NativePtr[String]` parameters (docs/70 phase 4a, D537).
spsrc=scripts/ci/native-via-tir/stringptr.l
"$lyric_bin" build --target native "$spsrc" -o "$work/sp_ast" >/dev/null
LYRIC_KEEP_LL=1 "$lyric_bin" build --target native --via-tir "$spsrc" -o "$work/sp_tir" 2> "$work/sp_census.txt" >/dev/null
cat "$work/sp_census.txt"
"$work/sp_ast" > "$work/sp_ast.out"
"$work/sp_tir" > "$work/sp_tir.out"
diff -u "$work/sp_ast.out" "$work/sp_tir.out"
printf 'dflt\ntrue\nabc\n' | diff -u - "$work/sp_tir.out"
if grep -q '^  fallback: ' "$work/sp_census.txt"; then
  echo "::error::stringptr.l has a TIR fallback"
  exit 1
fi
clang -O1 -g -fsanitize=address -Wno-override-module "$work/sp_tir.ll" lyric-rt/build-asan-tir/lyric_rt.a -lm -lpthread -ldl -o "$work/sp_asan"
"$work/sp_asan" > "$work/sp_asan.out"
diff -u "$work/sp_tir.out" "$work/sp_asan.out"
echo "string pointers under AddressSanitizer: clean"

# String methods that are one runtime call, numeric conversions and `panic`.
bsrc=scripts/ci/native-via-tir/builtins.l
"$lyric_bin" build --target native "$bsrc" -o "$work/b_ast" >/dev/null
LYRIC_KEEP_LL=1 "$lyric_bin" build --target native --via-tir "$bsrc" -o "$work/b_tir" 2> "$work/b_census.txt" >/dev/null
cat "$work/b_census.txt"
"$work/b_ast" > "$work/b_ast.out" 2> "$work/b_ast.err" || true
"$work/b_tir" > "$work/b_tir.out" 2> "$work/b_tir.err" || true
diff -u "$work/b_ast.out" "$work/b_tir.out"
printf 'HELLO\ncde|fgh\nbonono\n65\ntrue\n5000000000\n1\n0.75\n' | diff -u - "$work/b_tir.out"
grep -q 'bad: last' "$work/b_tir.err" || { echo "::error::the TIR build did not panic with the message"; cat "$work/b_tir.err"; exit 1; }
grep -q 'bad: last' "$work/b_ast.err" || { echo "::error::the AST build did not panic with the message"; exit 1; }
grep -q '^native via-TIR: 10 of 10 functions lowered from TIR' "$work/b_census.txt" || {
  echo "::error::expected every function of builtins.l to be lowered from TIR"
  exit 1
}
clang -O1 -g -fsanitize=address -Wno-override-module "$work/b_tir.ll" lyric-rt/build-asan-tir/lyric_rt.a -lm -lpthread -ldl -o "$work/b_asan"
"$work/b_asan" > "$work/b_asan.out" 2>/dev/null || true
diff -u "$work/b_tir.out" "$work/b_asan.out"
echo "builtins under AddressSanitizer: clean"

# Lists and slices (docs/70 phase 4a): literals, newList, add/removeAt/clear, indexing, element
# assignment and `for` over scalar and reference elements from TIR, then under AddressSanitizer.
lsrc=scripts/ci/native-via-tir/lists.l
"$lyric_bin" build --target native "$lsrc" -o "$work/l_ast" >/dev/null
LYRIC_KEEP_LL=1 "$lyric_bin" build --target native --via-tir "$lsrc" -o "$work/l_tir" 2> "$work/l_census.txt" >/dev/null
cat "$work/l_census.txt"
"$work/l_ast" > "$work/l_ast.out"
"$work/l_tir" > "$work/l_tir.out"
diff -u "$work/l_ast.out" "$work/l_tir.out"
printf '10\n14\n55\na,b,\n6\nwYz3\n0\n144\n3102111\n' | diff -u - "$work/l_tir.out"
grep -q '^native via-TIR: 11 of 11 functions lowered from TIR' "$work/l_census.txt" || {
  echo "::error::expected every function of lists.l to be lowered from TIR"
  exit 1
}
clang -O1 -g -fsanitize=address -Wno-override-module "$work/l_tir.ll" lyric-rt/build-asan-tir/lyric_rt.a -lm -lpthread -ldl -o "$work/l_asan"
"$work/l_asan" > "$work/l_asan.out"
diff -u "$work/l_tir.out" "$work/l_asan.out"
echo "lists under AddressSanitizer: clean"

# Maps (docs/70 phase 4a): newMap, add, containsKey, remove, count, `m[k]` and `m[k] = v` from TIR,
# then under AddressSanitizer.
msrc=scripts/ci/native-via-tir/maps.l
"$lyric_bin" build --target native "$msrc" -o "$work/m_ast" >/dev/null
LYRIC_KEEP_LL=1 "$lyric_bin" build --target native --via-tir "$msrc" -o "$work/m_tir" 2> "$work/m_census.txt" >/dev/null
cat "$work/m_census.txt"
"$work/m_ast" > "$work/m_ast.out"
"$work/m_tir" > "$work/m_tir.out"
diff -u "$work/m_ast.out" "$work/m_tir.out"
printf '3213\ntwo:20\nthree:30\nnone\n2\n' | diff -u - "$work/m_tir.out"
grep -q '^native via-TIR: 5 of 5 functions lowered from TIR' "$work/m_census.txt" || {
  echo "::error::expected every function of maps.l to be lowered from TIR"
  exit 1
}
clang -O1 -g -fsanitize=address -Wno-override-module "$work/m_tir.ll" lyric-rt/build-asan-tir/lyric_rt.a -lm -lpthread -ldl -o "$work/m_asan"
"$work/m_asan" > "$work/m_asan.out"
diff -u "$work/m_tir.out" "$work/m_asan.out"
echo "maps under AddressSanitizer: clean"

# Async functions (docs/70 phase 4a): coroutines with task completion and retained parameters, calls
# that await in place, `spawn` in a `scope` with `await` on the handle, from TIR, then the same IR
# under AddressSanitizer.
asrc=scripts/ci/native-via-tir/async.l
"$lyric_bin" build --target native "$asrc" -o "$work/a_ast" >/dev/null
LYRIC_KEEP_LL=1 "$lyric_bin" build --target native --via-tir "$asrc" -o "$work/a_tir" 2> "$work/a_census.txt" >/dev/null
cat "$work/a_census.txt"
"$work/a_ast" > "$work/a_ast.out"
"$work/a_tir" > "$work/a_tir.out"
diff -u "$work/a_ast.out" "$work/a_tir.out"
printf '42\n42\nhello ann!\nnote a\n333\n7\n' | diff -u - "$work/a_tir.out"
grep -q '^native via-TIR: 9 of 9 functions lowered from TIR' "$work/a_census.txt" || {
  echo "::error::expected every function of async.l to be lowered from TIR"
  exit 1
}
clang -O1 -g -fsanitize=address -Wno-override-module "$work/a_tir.ll" lyric-rt/build-asan-tir/lyric_rt.a -lm -lpthread -ldl -o "$work/a_asan"
"$work/a_asan" > "$work/a_asan.out"
diff -u "$work/a_tir.out" "$work/a_asan.out"
echo "async under AddressSanitizer: clean"

# Interfaces (docs/70 phase 4a): a heap record used as an interface and calls through the box,
# from TIR, then under AddressSanitizer.  The impl methods lower too, and so does `pick`, whose branches
# are converted to the interface (D483): 10 of 10 lower.
isrc=scripts/ci/native-via-tir/ifaces.l
"$lyric_bin" build --target native "$isrc" -o "$work/i_ast" >/dev/null
LYRIC_KEEP_LL=1 "$lyric_bin" build --target native --via-tir "$isrc" -o "$work/i_tir" 2> "$work/i_census.txt" >/dev/null
cat "$work/i_census.txt"
"$work/i_ast" > "$work/i_ast.out"
"$work/i_tir" > "$work/i_tir.out"
diff -u "$work/i_ast.out" "$work/i_tir.out"
printf 'rect r=6/18\nsquare 4=16/48\nrect big=20/60\nsquare 6=36/108\n24\n' | diff -u - "$work/i_tir.out"
grep -q '^native via-TIR: 10 of 10 functions lowered from TIR' "$work/i_census.txt" || {
  echo "::error::expected every function of ifaces.l to be lowered from TIR"
  exit 1
}
clang -O1 -g -fsanitize=address -Wno-override-module "$work/i_tir.ll" lyric-rt/build-asan-tir/lyric_rt.a -lm -lpthread -ldl -o "$work/i_asan"
"$work/i_asan" > "$work/i_asan.out"
diff -u "$work/i_tir.out" "$work/i_asan.out"
echo "interfaces under AddressSanitizer: clean"

# Methods declared in a record's body (docs/70 phase 4a): the receiver is the first parameter and
# direct calls lower from TIR too, then under AddressSanitizer.
mesrc=scripts/ci/native-via-tir/methods.l
"$lyric_bin" build --target native "$mesrc" -o "$work/me_ast" >/dev/null
LYRIC_KEEP_LL=1 "$lyric_bin" build --target native --via-tir "$mesrc" -o "$work/me_tir" 2> "$work/me_census.txt" >/dev/null
cat "$work/me_census.txt"
"$work/me_ast" > "$work/me_ast.out"
"$work/me_tir" > "$work/me_tir.out"
diff -u "$work/me_ast.out" "$work/me_tir.out"
printf '5\nc=5\n13\nc=7\n5\n20\n' | diff -u - "$work/me_tir.out"
grep -q '^native via-TIR: 6 of 6 functions lowered from TIR' "$work/me_census.txt" || {
  echo "::error::expected every function of methods.l to be lowered from TIR"
  exit 1
}
clang -O1 -g -fsanitize=address -Wno-override-module "$work/me_tir.ll" lyric-rt/build-asan-tir/lyric_rt.a -lm -lpthread -ldl -o "$work/me_asan"
"$work/me_asan" > "$work/me_asan.out"
diff -u "$work/me_tir.out" "$work/me_asan.out"
echo "methods under AddressSanitizer: clean"

# Protected types (docs/70 phase 4a): an entry's or function's body reads and writes the object's
# fields and `main` constructs the object (with its mutex) from TIR (the lock stays in the AST path's
# wrapper), then under AddressSanitizer.
prsrc=scripts/ci/native-via-tir/protected.l
"$lyric_bin" build --target native "$prsrc" -o "$work/pr_ast" >/dev/null
LYRIC_KEEP_LL=1 "$lyric_bin" build --target native --via-tir "$prsrc" -o "$work/pr_tir" 2> "$work/pr_census.txt" >/dev/null
cat "$work/pr_census.txt"
"$work/pr_ast" > "$work/pr_ast.out"
"$work/pr_tir" > "$work/pr_tir.out"
diff -u "$work/pr_ast.out" "$work/pr_tir.out"
printf '3\n7\ntotal\ntotal=7\n7\n50\n' | diff -u - "$work/pr_tir.out"
grep -q '^native via-TIR: 7 of 7 functions lowered from TIR' "$work/pr_census.txt" || {
  echo "::error::expected every function of protected.l (the five bodies, seed and the constructing main) to be lowered from TIR"
  exit 1
}
clang -O1 -g -fsanitize=address -Wno-override-module "$work/pr_tir.ll" lyric-rt/build-asan-tir/lyric_rt.a -lm -lpthread -ldl -o "$work/pr_asan"
"$work/pr_asan" > "$work/pr_asan.out"
diff -u "$work/pr_tir.out" "$work/pr_asan.out"
echo "protected types under AddressSanitizer: clean"

# By-value elements and compound element assignment (docs/70 phase 4a): a by-value record in a list
# or map is a counted box copied in and out, `xs[i] += v` and `m[k] += v`, and the `mapKeys` and
# `mapValues` snapshots, from TIR, then under AddressSanitizer (a leaked or doubly released box
# fails the run).
esrc=scripts/ci/native-via-tir/elems.l
"$lyric_bin" build --target native "$esrc" -o "$work/e_ast" >/dev/null
LYRIC_KEEP_LL=1 "$lyric_bin" build --target native --via-tir "$esrc" -o "$work/e_tir" 2> "$work/e_census.txt" >/dev/null
cat "$work/e_census.txt"
"$work/e_ast" > "$work/e_ast.out"
"$work/e_tir" > "$work/e_tir.out"
diff -u "$work/e_ast.out" "$work/e_tir.out"
printf '37\n4\n27\n32\nonly4\na!b!c!vxxx\n' | diff -u - "$work/e_tir.out"
grep -q '^native via-TIR: 8 of 8 functions lowered from TIR' "$work/e_census.txt" || {
  echo "::error::expected every function of elems.l to be lowered from TIR"
  exit 1
}
clang -O1 -g -fsanitize=address -Wno-override-module "$work/e_tir.ll" lyric-rt/build-asan-tir/lyric_rt.a -lm -lpthread -ldl -o "$work/e_asan"
"$work/e_asan" > "$work/e_asan.out"
diff -u "$work/e_tir.out" "$work/e_asan.out"
echo "by-value elements under AddressSanitizer: clean"

# Record patterns (docs/70 phase 4a): `match` arms and destructuring `val` on a by-value and a heap
# record lowered from TIR, then under AddressSanitizer.  The AST lowering has no record patterns, so
# there is no plain build to compare with: the output is the specified one.
rpsrc=scripts/ci/native-via-tir/recpat.l
LYRIC_KEEP_LL=1 "$lyric_bin" build --target native --via-tir "$rpsrc" -o "$work/rp_tir" 2> "$work/rp_census.txt" >/dev/null
cat "$work/rp_census.txt"
"$work/rp_tir" > "$work/rp_tir.out"
printf '7\n300\n7\nR4\nleaf!\nleaf2\n42\n8\n' | diff -u - "$work/rp_tir.out"
grep -q '^native via-TIR: 5 of 5 functions lowered from TIR' "$work/rp_census.txt" || {
  echo "::error::expected every function of recpat.l to be lowered from TIR"
  exit 1
}
clang -O1 -g -fsanitize=address -Wno-override-module "$work/rp_tir.ll" lyric-rt/build-asan-tir/lyric_rt.a -lm -lpthread -ldl -o "$work/rp_asan"
"$work/rp_asan" > "$work/rp_asan.out"
diff -u "$work/rp_tir.out" "$work/rp_asan.out"
echo "record patterns under AddressSanitizer: clean"

# Arrays of references (docs/70 phase 4a): a counted list on native, copied at a store (`XArrayCopy`),
# zero filled (`XZeroValue`), indexed with the array's own bounds check, from TIR, then under
# AddressSanitizer (a leaked or doubly released element or list fails the run).
arsrc=scripts/ci/native-via-tir/arrayrefs.l
"$lyric_bin" build --target native "$arsrc" -o "$work/arr_ast" >/dev/null
LYRIC_KEEP_LL=1 "$lyric_bin" build --target native --via-tir "$arsrc" -o "$work/arr_tir" 2> "$work/arr_census.txt" >/dev/null
cat "$work/arr_census.txt"
"$work/arr_ast" > "$work/arr_ast.out"
"$work/arr_tir" > "$work/arr_tir.out"
diff -u "$work/arr_ast.out" "$work/arr_tir.out"
printf 'x,yy,xyy,\npZ2\n9\nab!\n' | diff -u - "$work/arr_tir.out"
if grep -q '^  fallback:' "$work/arr_census.txt"; then
  echo "::error::arrayrefs.l has a TIR fallback"
  exit 1
fi
clang -O1 -g -fsanitize=address -Wno-override-module "$work/arr_tir.ll" lyric-rt/build-asan-tir/lyric_rt.a -lm -lpthread -ldl -o "$work/arr_asan"
"$work/arr_asan" > "$work/arr_asan.out"
diff -u "$work/arr_tir.out" "$work/arr_asan.out"
echo "arrays of references under AddressSanitizer: clean"

# Inline arrays (docs/70 phase 4a): element reads and writes through the element's address,
# compound assignment, nested arrays, arrays in by-value and heap records, `for`, `.length` and an
# array of by-value records from TIR; an out-of-range index panics with the AST path's message.
arrsrc=scripts/ci/native-via-tir/arrays.l
"$lyric_bin" build --target native "$arrsrc" -o "$work/ar_ast" >/dev/null
LYRIC_KEEP_LL=1 "$lyric_bin" build --target native --via-tir "$arrsrc" -o "$work/ar_tir" 2> "$work/ar_census.txt" >/dev/null
cat "$work/ar_census.txt"
"$work/ar_ast" > "$work/ar_ast.out"
"$work/ar_tir" > "$work/ar_tir.out"
diff -u "$work/ar_ast.out" "$work/ar_tir.out"
printf '14\n9\n3\n2\n21\n10\n5\n21\n9\n77\n11\n72\n13\n' | diff -u - "$work/ar_tir.out"
if grep -q '^  fallback:' "$work/ar_census.txt"; then
  echo "::error::arrays.l has a TIR fallback"
  exit 1
fi
clang -O1 -g -fsanitize=address -Wno-override-module "$work/ar_tir.ll" lyric-rt/build-asan-tir/lyric_rt.a -lm -lpthread -ldl -o "$work/ar_asan"
"$work/ar_asan" > "$work/ar_asan.out"
diff -u "$work/ar_tir.out" "$work/ar_asan.out"
echo "arrays under AddressSanitizer: clean"
cat > "$work/oob.l" <<'LYRICSRC'
package OobViaTir

func get(a: in array[3, Int], i: in Int): Int {
  a[i]
}

func main(): Unit {
  println(toString(get([1, 2, 3], 2)))
  println(toString(get([1, 2, 3], 3)))
}
LYRICSRC
"$lyric_bin" build --target native "$work/oob.l" -o "$work/oob_ast" >/dev/null
"$lyric_bin" build --target native --via-tir "$work/oob.l" -o "$work/oob_tir" 2> "$work/oob_census.txt" >/dev/null
if grep -q '^  fallback:' "$work/oob_census.txt"; then
  cat "$work/oob_census.txt"
  echo "::error::the out-of-range program has a TIR fallback"
  exit 1
fi
for which in ast tir; do
  if "$work/oob_$which" > "$work/oob_$which.out" 2> "$work/oob_$which.err"; then
    echo "::error::the $which build did not panic on an out-of-range index"
    exit 1
  fi
  grep -q 'index 3 out of range for array\[3\]' "$work/oob_$which.err" || {
    echo "::error::the $which panic lacks the index message"
    cat "$work/oob_$which.err"
    exit 1
  }
done
diff -u "$work/oob_ast.out" "$work/oob_tir.out"
echo "arrays: ok"

# Numeric conversions and bitwise methods (docs/70 phase 4a, D532): the conversion family, the checked
# `toNat` and `toChar`, a `Float` receiver and `.and/.or/.xor/.shl/.shr` from TIR, then under
# AddressSanitizer; a negative `toNat` and a surrogate `toChar` panic with the AST path's message.
numsrc=scripts/ci/native-via-tir/numeric.l
"$lyric_bin" build --target native "$numsrc" -o "$work/nu_ast" >/dev/null
LYRIC_KEEP_LL=1 "$lyric_bin" build --target native --via-tir "$numsrc" -o "$work/nu_tir" 2> "$work/nu_census.txt" >/dev/null
cat "$work/nu_census.txt"
"$work/nu_ast" > "$work/nu_ast.out"
"$work/nu_tir" > "$work/nu_tir.out"
diff -u "$work/nu_ast.out" "$work/nu_tir.out"
printf '99999998461.75\n252\n1705033304\n12\n198\n3900151661\n-8\n' | diff -u - "$work/nu_tir.out"
if grep -q '^  fallback:' "$work/nu_census.txt"; then
  echo "::error::numeric.l has a TIR fallback"
  exit 1
fi
clang -O1 -g -fsanitize=address -Wno-override-module "$work/nu_tir.ll" lyric-rt/build-asan-tir/lyric_rt.a -lm -lpthread -ldl -o "$work/nu_asan"
"$work/nu_asan" > "$work/nu_asan.out"
diff -u "$work/nu_tir.out" "$work/nu_asan.out"
echo "numeric under AddressSanitizer: clean"
for case in 'Int:(0 - 5).toNat()' 'Char:(55296).toChar()'; do
  cname=${case%%:*}
  cexpr=${case#*:}
  cat > "$work/numpanic_$cname.l" <<LYRICSRC
package NumPanicViaTir

func main(): Unit {
  println(toString($cexpr))
}
LYRICSRC
  "$lyric_bin" build --target native "$work/numpanic_$cname.l" -o "$work/np_ast" >/dev/null
  "$lyric_bin" build --target native --via-tir "$work/numpanic_$cname.l" -o "$work/np_tir" 2> "$work/np_census.txt" >/dev/null
  if grep -q '^  fallback:' "$work/np_census.txt"; then
    cat "$work/np_census.txt"
    echo "::error::the $cname panic program has a TIR fallback"
    exit 1
  fi
  for which in ast tir; do
    if "$work/np_$which" > /dev/null 2> "$work/np_$which.err"; then
      echo "::error::the $which build of the $cname conversion did not panic"
      exit 1
    fi
  done
  grep -o 'to[A-Za-z]*: .*' "$work/np_ast.err" | head -1 > "$work/np_ast.msg"
  grep -o 'to[A-Za-z]*: .*' "$work/np_tir.err" | head -1 > "$work/np_tir.msg"
  test -s "$work/np_tir.msg" || { echo "::error::no panic message for $cname"; cat "$work/np_tir.err"; exit 1; }
  diff -u "$work/np_ast.msg" "$work/np_tir.msg"
done
echo "numeric: ok"

# Contract clauses and `?` (docs/70 phase 4a part 6, D502, D503): lowered on TIR before monomorphisation,
# every function from TIR, the same output, and the same panic message when a clause is violated.
csrc=scripts/ci/native-via-tir/contracts.l
"$lyric_bin" build --target native "$csrc" -o "$work/c_ast" >/dev/null
"$lyric_bin" build --target native --via-tir "$csrc" -o "$work/c_tir" 2> "$work/c_census.txt" >/dev/null
cat "$work/c_census.txt"
"$work/c_ast" > "$work/c_ast.out"
"$work/c_tir" > "$work/c_tir.out"
diff -u "$work/c_ast.out" "$work/c_tir.out"
printf '5\n10\n0\n4\n14\nbad\n3\nnone\n' | diff -u - "$work/c_tir.out"
grep -q '^native via-TIR: 6 of 6 functions lowered from TIR' "$work/c_census.txt" || {
  echo "::error::expected every function of contracts.l to be lowered from TIR"
  exit 1
}
sed -e 's|^func main(): Unit {|func main(): Unit {\n  println(toString(half(0 - 1)))|' "$csrc" > "$work/contracts_violated.l"
"$lyric_bin" build --target native "$work/contracts_violated.l" -o "$work/cv_ast" >/dev/null
"$lyric_bin" build --target native --via-tir "$work/contracts_violated.l" -o "$work/cv_tir" 2> "$work/cv_census.txt" >/dev/null
if grep -q '^  fallback:' "$work/cv_census.txt"; then
  cat "$work/cv_census.txt"
  echo "::error::the violated-contract program has a TIR fallback"
  exit 1
fi
for which in ast tir; do
  if "$work/cv_$which" > /dev/null 2> "$work/cv_$which.err"; then
    echo "::error::the $which build did not panic on a violated precondition"
    exit 1
  fi
done
grep -o 'PreconditionViolated: .*' "$work/cv_ast.err" | head -1 > "$work/cv_ast.msg"
grep -o 'PreconditionViolated: .*' "$work/cv_tir.err" | head -1 > "$work/cv_tir.msg"
test -s "$work/cv_tir.msg" || { echo "::error::no precondition message"; cat "$work/cv_tir.err"; exit 1; }
diff -u "$work/cv_ast.msg" "$work/cv_tir.msg"
echo "contracts: ok"

# Module-level `val`s (docs/70 phase 4a part 6, D535): literals inlined, strings built at the read, computed
# values behind `mvensure`, every function from TIR, the same output, then under AddressSanitizer.
gsrc=scripts/ci/native-via-tir/globals.l
"$lyric_bin" build --target native "$gsrc" -o "$work/g_ast" >/dev/null
LYRIC_KEEP_LL=1 "$lyric_bin" build --target native --via-tir "$gsrc" -o "$work/g_tir" 2> "$work/g_census.txt" >/dev/null
cat "$work/g_census.txt"
"$work/g_ast" > "$work/g_ast.out"
"$work/g_tir" > "$work/g_tir.out"
diff -u "$work/g_ast.out" "$work/g_tir.out"
printf '42\n6000000000\n82\ngv\nhello gv\nhello gv\n-5x1.5true\n' | diff -u - "$work/g_tir.out"
grep -q '^native via-TIR: 9 of 9 functions lowered from TIR' "$work/g_census.txt" || {
  echo "::error::expected every function of globals.l to be lowered from TIR"
  exit 1
}
clang -O1 -g -fsanitize=address -Wno-override-module "$work/g_tir.ll" lyric-rt/build-asan-tir/lyric_rt.a -lm -lpthread -ldl -o "$work/g_asan"
"$work/g_asan" > "$work/g_asan.out"
diff -u "$work/g_tir.out" "$work/g_asan.out"
echo "globals under AddressSanitizer: clean"

# Integer overflow (D163): the checks the elaborator would have rewritten into the AST.
LYRIC_BIN="$lyric_bin" bash scripts/ci/native-via-tir-overflow-e2e.sh

echo "native-via-tir-e2e: ok"
