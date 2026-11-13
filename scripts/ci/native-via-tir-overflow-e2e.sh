#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# native-via-tir-overflow-e2e.sh - integer overflow (D163) through the TIR path.
#
# The overflow pass rewrites the AST the TIR is built from, so the TIR lowering
# emits the checks itself.  Each case below builds one program the plain way and
# with --via-tir, and requires the same panic message and a non-zero exit from
# both; the in-range case requires the same output.  Every function must lower
# from TIR (no fallback), so the check is the lowering's, not the AST path's.
#
# Usage: LYRIC_BIN=<lyric> bash scripts/ci/native-via-tir-overflow-e2e.sh
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
lyric_bin="${LYRIC_BIN:-./bin/lyric}"
work="$(mktemp -d "${TMPDIR:-/tmp}/via-tir-ovf.XXXXXX")"
trap 'rm -rf "$work"' EXIT

prelude='package OvfViaTir

func idI(x: in Int): Int { x }
func idL(x: in Long): Long { x }
func idU(x: in UInt): UInt { x }
func idUL(x: in ULong): ULong { x }
'

# name | type | expression | expected message
cases=(
  "int_add|Int|idI(2147483647) + idI(1)|arithmetic overflow: Int addition"
  "int_sub|Int|(0 - idI(2147483647)) - idI(2)|arithmetic overflow: Int subtraction"
  "int_mul|Int|idI(65536) * idI(65536)|arithmetic overflow: Int multiplication"
  "int_neg|Int|-((0 - idI(2147483647)) - idI(1))|arithmetic overflow: Int negation"
  "long_add|Long|idL(9223372036854775807i64) + idL(1i64)|arithmetic overflow: Long addition"
  "long_mul|Long|idL(4611686018427387904i64) * idL(2i64)|arithmetic overflow: Long multiplication"
  "uint_add|UInt|idU(4294967295u32) + idU(1u32)|arithmetic overflow: UInt addition"
  "uint_sub|UInt|idU(0u32) - idU(1u32)|arithmetic overflow: UInt subtraction"
  "ulong_add|ULong|idUL(18446744073709551615u64) + idUL(1u64)|arithmetic overflow: ULong addition"
  "ulong_mul|ULong|idUL(9223372036854775808u64) * idUL(2u64)|arithmetic overflow: ULong multiplication"
)

for c in "${cases[@]}"; do
  IFS='|' read -r name ty expr msg <<<"$c"
  src="$work/$name.l"
  {
    printf '%s\n' "$prelude"
    printf 'func main(): Unit {\n  val r: %s = %s\n  println(toString(r))\n}\n' "$ty" "$expr"
  } > "$src"
  "$lyric_bin" build --target native "$src" -o "$work/$name.ast" >/dev/null
  "$lyric_bin" build --target native --via-tir "$src" -o "$work/$name.tir" 2> "$work/$name.census" >/dev/null
  if grep -q '^  fallback:' "$work/$name.census"; then
    cat "$work/$name.census"
    echo "::error::$name has a TIR fallback"
    exit 1
  fi
  if "$work/$name.ast" > /dev/null 2> "$work/$name.ast.err"; then
    echo "::error::$name: the AST build did not panic"
    exit 1
  fi
  if "$work/$name.tir" > /dev/null 2> "$work/$name.tir.err"; then
    echo "::error::$name: the TIR build did not panic"
    exit 1
  fi
  grep -q "$msg" "$work/$name.ast.err" || { echo "::error::$name: AST panic lacks '$msg'"; cat "$work/$name.ast.err"; exit 1; }
  grep -q "$msg" "$work/$name.tir.err" || { echo "::error::$name: TIR panic lacks '$msg'"; cat "$work/$name.tir.err"; exit 1; }
  echo "$name: panics with '$msg' on both paths"
done

# In range at the boundary: no panic, same output.
src="$work/inrange.l"
cat > "$src" <<'LYRICSRC'
package OvfViaTir

func idI(x: in Int): Int { x }
func idL(x: in Long): Long { x }
func idU(x: in UInt): UInt { x }
func idUL(x: in ULong): ULong { x }

func main(): Unit {
  println(toString(idI(2147483647) - idI(1) + idI(1)))
  println(toString(idI(46340) * idI(46340)))
  println(toString(idL(3037000499i64) * idL(3037000499i64)))
  println(toString(idL(0i64) - idL(9223372036854775807i64)))
  println(toString(idU(4294967295u32) - idU(1u32)))
  println(toString(idUL(18446744073709551615u64) - idUL(1u64)))
  println(toString(idUL(4294967296u64) * idUL(4294967295u64)))
  println(toString(-idI(2147483647)))
}
LYRICSRC
"$lyric_bin" build --target native "$src" -o "$work/inrange.ast" >/dev/null
"$lyric_bin" build --target native --via-tir "$src" -o "$work/inrange.tir" 2> "$work/inrange.census" >/dev/null
cat "$work/inrange.census"
"$work/inrange.ast" > "$work/inrange.ast.out"
"$work/inrange.tir" > "$work/inrange.tir.out"
diff -u "$work/inrange.ast.out" "$work/inrange.tir.out"
grep -q '^native via-TIR: 5 of 5 functions lowered from TIR' "$work/inrange.census" || {
  echo "::error::expected every function of the in-range program to be lowered from TIR"
  exit 1
}
echo "native-via-tir-overflow-e2e: ok"
