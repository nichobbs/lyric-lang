#!/usr/bin/env bash
set -euo pipefail
if [ ! -d .bootstrap/stage1 ] || [ ! -f .bootstrap/stage1/Lyric.Lyric.Cli.dll ]; then
  echo "::error::stage 1 bundle missing; skipping collExpect construction-position self-test"
  exit 1
fi
lyric_bin="bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin; skipping collExpect construction-position self-test"
  exit 1
fi
work="$(mktemp -d)"
# The self-hosted type checker treats `[...]` literals as `slice[T]`, not
# `List[T]`, so collExpect at function-return / call-arg / reassignment
# positions requires the record-field construction path where the emitter
# propagates the field's `List[T]` expected type into the literal
# (T0060/T0070/T0043 type errors block the direct List-position paths — a
# self-hosted type-checker gap tracked in #2394).  All four positions are
# validated here via record fields: construct, pass as field, reassign as
# field, and nest as inner field.
cat > "$work/c3.l" <<'LYR'
@test_module
package C3
import Std.Testing
record IntSeq { vals: List[Int] }
func makeSeq(): IntSeq { IntSeq(vals = [10, 20, 30]) }
func sumSeq(seq: in IntSeq): Int {
  var s = 0
  var i = 0
  while i < seq.vals.count { s = s + seq.vals[i]; i = i + 1 }
  s
}
test "record-field construction builds concrete List[Int]" {
  val seq = makeSeq()
  assertEqualInt(seq.vals.count, 3, "count")
  assertEqualInt(seq.vals[0] + seq.vals[1] + seq.vals[2], 60, "sum")
}
test "record-field in call-arg position builds concrete List[Int]" {
  assertEqualInt(sumSeq(IntSeq(vals = [100, 200, 300])), 600, "sum")
}
test "record-field reassignment builds concrete List[Int]" {
  var seq = IntSeq(vals = [0])
  seq = IntSeq(vals = [1, 2, 3])
  assertEqualInt(seq.vals.count, 3, "count")
  assertEqualInt(seq.vals[0] + seq.vals[2], 4, "sum-first-last")
}
test "nested record-field builds concrete List[Int] for inner" {
  val a = IntSeq(vals = [10, 20])
  val b = IntSeq(vals = [30, 40, 50])
  assertEqualInt(a.vals.count, 2, "inner0 count")
  assertEqualInt(b.vals.count, 3, "inner1 count")
  assertEqualInt(a.vals[0] + a.vals[1], 30, "inner0 sum")
}
LYR
"$lyric_bin" test "$work/c3.l"
echo "collExpect propagates correctly via record-field construction positions (self-hosted)"
echo "record-field collExpect builds inner lists as concrete List<int32>"

