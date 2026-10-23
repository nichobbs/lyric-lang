#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# windows-native-tests.sh — the `--target native` suite on Windows x86-64
# (docs/67 G9, x86_64-pc-windows-msvc), run on a Windows host from Git Bash.
#
#   1. Builds lyric-rt with CMake, Ninja and clang and runs its C unit tests
#      (lyric_rt_test, lyric_win32_test, lyric_parallel_test).
#   2. Runs the cross-target @test_module suites and the stdlib suites the
#      Linux native lane runs (scripts/ci/native-backend-self-tests.sh) with
#      `lyric test --target native`.  The suites that need child processes,
#      sockets or TLS are not listed: those runtime layers are not ported yet
#      (they report the documented failure on Windows).
#   3. Builds and runs programs that check what is Windows-specific end to
#      end: the `.exe` output name, by-value records crossing to C under the
#      Microsoft x64 convention, UTF-8 console output and arguments, files
#      with non-ASCII names, the environment, and a panic's exit status.
#
# Needs clang and lld-link (an LLVM install) and the MSVC C runtime and
# Windows SDK (Visual Studio Build Tools), CMake and Ninja on PATH.
#
# Usage: LYRIC_BIN=path/to/lyric.exe bash scripts/ci/windows-native-tests.sh
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

lyric_bin="${LYRIC_BIN:?set LYRIC_BIN to the lyric executable}"
triple="x86_64-pc-windows-msvc"
work="$(mktemp -d)"

echo "=== lyric-rt (CMake, Ninja, clang) ==="
rt_build="$work/lyric-rt"
cmake -S lyric-rt -B "$rt_build" -G Ninja -DCMAKE_C_COMPILER=clang -DCMAKE_BUILD_TYPE=Release
cmake --build "$rt_build"
ctest --test-dir "$rt_build" --output-on-failure
LYRIC_RT_WINDOWS_PATH="$(cygpath -m "$rt_build/lyric_rt.lib")"
export LYRIC_RT_WINDOWS_PATH

echo "=== cross-target suites (--target native) ==="
for t in \
  lyric-compiler/lyric/slice_fastpath_self_test.l \
  lyric-compiler/lyric/labelled_loops_self_test.l \
  lyric-compiler/lyric/distinct_ops_self_test.l \
  lyric-compiler/lyric/record_semantics_self_test.l \
  lyric-compiler/lyric/float32_self_test.l \
  lyric-compiler/lyric/record_arith_self_test.l \
  lyric-compiler/lyric/overflow_self_test.l \
  lyric-compiler/lyric/record_eq_self_test.l \
  lyric-compiler/lyric/byvalue_record_self_test.l \
  lyric-compiler/lyric/inline_union_self_test.l \
  lyric-compiler/lyric/generic_ctor_open_arg_self_test.l \
  lyric-compiler/lyric/generic_ctor_widening_self_test.l \
  lyric-compiler/lyric/named_arg_eval_order_self_test.l \
  lyric-compiler/lyric/inout_receiver_self_test.l \
  lyric-compiler/lyric/inout_array_element_self_test.l \
  lyric-compiler/lyric/dot_named_byref_self_test.l \
  lyric-compiler/lyric/dot_named_primitive_self_test.l \
  lyric-compiler/lyric/type_qualified_method_self_test.l \
  lyric-compiler/lyric/protected_byref_self_test.l \
  lyric-compiler/lyric/inout_aliasing_self_test.l \
  lyric-compiler/lyric/byref_value_type_self_test.l \
  lyric-compiler/lyric/slice_func_elem_self_test.l \
  lyric-compiler/lyric/closure_correctness_self_test.l \
  lyric-compiler/lyric/hoisted_literal_shape_self_test.l \
  lyric-compiler/lyric/member_local_shadow_self_test.l \
  lyric-compiler/lyric/closure_shadow_self_test.l \
  lyric-compiler/lyric/literal_arg_shape_self_test.l \
  lyric-compiler/lyric/generic_closure_self_test.l \
  lyric-compiler/lyric/inout_self_param_self_test.l \
  lyric-compiler/lyric/propagate_ctor_operand_self_test.l \
  lyric-compiler/lyric/fixed_array_self_test.l \
  lyric-compiler/lyric/buffer_self_test.l \
  lyric-compiler/lyric/buffer_spawn_self_test.l \
  lyric-compiler/lyric/value_generic_record_self_test.l \
  lyric-compiler/lyric/value_generic_protected_self_test.l \
  lyric-compiler/lyric/dotted_generic_func_self_test.l \
  lyric-compiler/lyric/structural_equality_self_test.l \
  lyric-compiler/lyric/func_default_args_self_test.l \
  lyric-compiler/lyric/method_default_args_self_test.l \
  lyric-compiler/lyric/bench_alloc_self_test.l \
  lyric-compiler/lyric/tuple_expected_type_self_test.l \
  lyric-compiler/lyric/protected_iface_impl_self_test.l \
  lyric-compiler/lyric/generic_protected_self_test.l \
  lyric-compiler/lyric/generic_opaque_self_test.l \
  lyric-compiler/lyric/record_field_closure_self_test.l \
  lyric-compiler/lyric/explicit_type_args_self_test.l \
  lyric-compiler/lyric/protected_iface_impl_self_type_self_test.l \
  lyric-compiler/lyric/byte_native_self_test.l \
  lyric-compiler/lyric/nested_nullary_pattern_native_self_test.l ; do
  echo "--- $t"
  "$lyric_bin" test --target native "$t"
done

echo "=== stdlib suites (--target native) ==="
for t in \
  lyric-stdlib/tests/task_native_tests.l \
  lyric-stdlib/tests/secure_random_native_tests.l \
  lyric-stdlib/tests/json_native_tests.l \
  lyric-stdlib/tests/json_value_tests.l \
  lyric-stdlib/tests/linalg_tests.l ; do
  echo "--- $t"
  "$lyric_bin" test --target native "$t"
done
"$lyric_bin" run --target native lyric-stdlib/tests/parse_tests.l

echo "=== Windows end-to-end programs ==="
bash scripts/ci/windows-native-e2e.sh "$lyric_bin" "$work/e2e"

echo "Windows native suite passed"
