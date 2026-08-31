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
