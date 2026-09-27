#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# native-target-smoke-test.sh — `lyric test --target native` smoke test
# (N7.2): compiles an ordinary `@test_module` (no compiler-package imports)
# through `Emitter.emitNative` and runs it as a self-contained binary — not
# via LYRIC_LOAD_COMPILER's in-process MSIL host.
#
# Builds lyric-rt into a PRIVATE directory (not the shared lyric-rt/build/
# the "native backend self-tests" step also builds into) so this step can
# run concurrently with that `background: true` step without racing its
# `make -C lyric-rt clean && make -C lyric-rt test CC=gcc` mid-run rm -rf of
# the shared build dir (observed: a clang link failure reading a
# mid-deletion .a file).
#
# Extracted from `.github/workflows/ci.yml`'s "native-backend-self-tests"
# job to keep the workflow file under GitHub's undocumented workflow-file
# size ceiling (issue #6781; see scripts/ci/check-workflow-size.sh's header).
#
# Usage: bash scripts/ci/native-target-smoke-test.sh
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

BUILD_CONFIG="${BUILD_CONFIG:-Debug}"

lyric_bin="bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric"
rt_build_dir="$(mktemp -d)/lyric-rt-build"
make -C lyric-rt BUILD="$rt_build_dir"
export LYRIC_RT_PATH="$rt_build_dir/lyric_rt.a"
work="$(mktemp -d)"
cat > "$work/pass_test.l" <<'LYR'
@test_module
package NativeTestSmoke

import Std.Testing

test "addition" {
  assertEqualInt(2 + 2, 4, "2+2==4")
}
LYR
"$lyric_bin" test "$work/pass_test.l" --target native
cat > "$work/fail_test.l" <<'LYR'
@test_module
package NativeTestSmokeFail

import Std.Testing

test "deliberately wrong" {
  assertEqualInt(2 + 2, 5, "2+2==5")
}
LYR
if "$lyric_bin" test "$work/fail_test.l" --target native; then
  echo "::error::expected a nonzero exit for a failing --target native test"
  exit 1
fi
echo "Native lyric test --target native smoke test passed"
"$lyric_bin" test lyric-compiler/lyric/indexof_native_self_test.l --target native
echo "Native indexof_native_self_test.l (--target native) passed"
"$lyric_bin" test lyric-compiler/lyric/split_self_test.l --target native
echo "Native split_self_test.l (--target native) passed"
"$lyric_bin" test lyric-compiler/lyric/string_builder_self_test.l --target native
echo "Native string_builder_self_test.l (--target native) passed"
"$lyric_bin" test lyric-compiler/lyric/string_ordinal_self_test.l --target native
echo "Native string_ordinal_self_test.l (--target native) passed"
"$lyric_bin" test lyric-compiler/lyric/string_case_locale_self_test.l --target native
echo "Native string_case_locale_self_test.l (--target native) passed"
"$lyric_bin" test lyric-compiler/lyric/slice_fastpath_self_test.l --target native
echo "Native slice_fastpath_self_test.l (--target native) passed"
# Integer literal ranges (#7346) and mixed-width arithmetic widening (#7350).
"$lyric_bin" test lyric-compiler/lyric/int_literal_range_self_test.l --target native
"$lyric_bin" test lyric-compiler/lyric/mixed_width_arith_self_test.l --target native
echo "Native int_literal_range / mixed_width_arith self-tests (--target native) passed"
# A bare `longToInt` resolves to the range-checked Std.Math.longToInt, not an
# unchecked truncation (#7465). Native has no try/catch, so the out-of-range
# case is checked from outside: the run must fail with the precondition. The
# dotnet/JVM half is conversion_name_resolution_self_test.l.
cat > "$work/long_to_int.l" <<'LYR'
package NativeLongToInt

import Std.Core
import Std.Console
import Std.Math

func main(): Unit {
  println(toString(longToInt(2147483647i64)))
  println(toString(Std.Math.longToInt(-2147483648i64)))
  println(toString(3000000000i64.toInt()))
  val big = 3000000000i64
  println(toString(longToInt(big)))
}
LYR
set +e
lti_out="$("$lyric_bin" run --target native "$work/long_to_int.l" 2>&1)"
lti_rc=$?
set -e
lti_values="$(printf '%s\n' "$lti_out" | grep -E '^-?[0-9]+$' | tr '\n' ' ')"
if [ "$lti_rc" -eq 0 ] \
  || [ "$lti_values" != "2147483647 -2147483648 -1294967296 " ] \
  || ! printf '%s\n' "$lti_out" | grep -q 'PreconditionViolated: Std.Math.longToInt'; then
  echo "::error::bare longToInt on --target native: expected the in-range values then a Std.Math.longToInt precondition failure (#7465), got exit $lti_rc:"
  printf '%s\n' "$lti_out"
  exit 1
fi
echo "Native bare longToInt precondition check (--target native) passed"
# Std.Collections.Persistent on native (#7413): zero-argument generic calls
# typed by the expected type, refutable tuple-element patterns, prelude
# println, and top-level functions passed as values.
"$lyric_bin" run --target native lyric-stdlib/tests/collections_persistent_tests.l
"$lyric_bin" run --target native lyric-stdlib/tests/collections_persistent_map_tests.l
echo "Native Std.Collections.Persistent suites (--target native) passed"
