#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# ffi-f0015-negative-test.sh — Auto-FFI F0015 signature-mismatch negative
# test (#2945) plus the F0027 hint-less-extern warning test (#5704,
# D-progress-671).
#
# The auto-FFI self-test covers only the happy path (valid signatures
# resolve), so a regression that silently disabled the signature-
# verification block in msil/codegen.l (e.g. `canVerify` or
# `isExplicitStatic` stuck false) would go undetected. This builds a
# fixture whose @externStatic @externTarget declares an arity that matches
# no System.Math.Max overload and asserts the build fails with F0015.
#
# F0027: a hint-less @externTarget whose calling convention can't be
# metadata-verified must WARN (not fail — option A is warning-first), and
# an explicit @externStatic/@externInstance must silence it. Task.Run's
# delegate parameter is unscoreable, so it is a stable unverifiable case.
#
# Extracted from `.github/workflows/ci.yml`'s "compiler-self-tests-dotnet-a"
# job to keep the workflow file under GitHub's undocumented workflow-file
# size ceiling (issue #6781; see scripts/ci/check-workflow-size.sh's header).
#
# Usage: bash scripts/ci/ffi-f0015-negative-test.sh
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

BUILD_CONFIG="${BUILD_CONFIG:-Debug}"

lyric_bin="bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin; skipping F0015 negative test"
  exit 1
fi
bin_abs="$(pwd)/$lyric_bin"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cat > "$work/f0015_fixture.l" <<'LYR'
package F0015Fixture

@externStatic
@externTarget("System.Math.Max")
func badMax(a: in Int): Int = ()

func main(): Int {
  badMax(1)
}
LYR
rc=0
( cd "$work" && "$bin_abs" build f0015_fixture.l ) > "$work/build.out" 2>&1 || rc=$?
echo "--- build output (rc=$rc) ---"; cat "$work/build.out"
if [ "$rc" -eq 0 ]; then
  echo "::error::expected non-zero exit for a mismatched @externTarget signature"
  exit 1
fi
grep -q "F0015" "$work/build.out" || {
  echo "::error::build failed but did not report F0015"; exit 1; }
echo "F0015 signature-mismatch negative test passed (rc=$rc)"

# F0027 (#5704, D-progress-671): a hint-less @externTarget whose
# calling convention can't be metadata-verified must WARN (not fail —
# option A is warning-first), and an explicit @externStatic/
# @externInstance must silence it. Task.Run's delegate parameter is
# unscoreable, so it is a stable unverifiable case.
cat > "$work/f0027_pos.l" <<'LYR'
package F0027Pos
extern type BclTask = "System.Threading.Tasks.Task"
@externTarget("System.Threading.Tasks.Task.Run")
func hintlessTaskRun(action: in () -> Unit): BclTask = ()
func main(): Int { 0 }
LYR
rc=0
( cd "$work" && "$bin_abs" build f0027_pos.l ) > "$work/f0027_pos.out" 2>&1 || rc=$?
echo "--- F0027 positive fixture (rc=$rc) ---"; cat "$work/f0027_pos.out"
if [ "$rc" -ne 0 ]; then
  echo "::error::F0027 is warning-first (option A) but the hint-less fixture failed the build"; exit 1
fi
grep -q "F0027" "$work/f0027_pos.out" || {
  echo "::error::hint-less unverifiable @externTarget did not warn F0027"; exit 1; }
cat > "$work/f0027_neg.l" <<'LYR'
package F0027Neg
extern type BclTask = "System.Threading.Tasks.Task"
@externStatic
@externTarget("System.Threading.Tasks.Task.Run")
func annotatedTaskRun(action: in () -> Unit): BclTask = ()
func main(): Int { 0 }
LYR
rc=0
( cd "$work" && "$bin_abs" build f0027_neg.l ) > "$work/f0027_neg.out" 2>&1 || rc=$?
echo "--- F0027 negative fixture (rc=$rc) ---"; cat "$work/f0027_neg.out"
if [ "$rc" -ne 0 ]; then
  echo "::error::annotated @externStatic fixture failed to build"; exit 1
fi
if grep -q "F0027" "$work/f0027_neg.out"; then
  echo "::error::explicit @externStatic did not silence F0027"; exit 1
fi
echo "F0027 hint-less-extern warning test passed"
