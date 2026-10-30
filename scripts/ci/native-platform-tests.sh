#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# native-platform-tests.sh -- the `--target native` suite on a host the main
# Linux x86-64 lane (native-backend-self-tests.sh) does not cover: macOS arm64
# (macos-latest, Apple clang) and Linux arm64 (ubuntu-24.04-arm), #8419, #8401.
#
#   1. Builds lyric-rt and runs its C unit tests with the host clang (and, on
#      Linux, gcc and the AddressSanitizer run of the TLS seam).
#   2. Runs the cross-target @test_module suites and the stdlib suites the
#      Linux native lane runs (scripts/ci/native-backend-self-tests.sh) with
#      `lyric test --target native`.
#   3. Stages the compiler bundle beside lyric and runs the compiler-hosted
#      native suites (`llvm_*_self_test.l` and friends), which codegen, link
#      and run Mach-O executables.
#
# Every suite runs even when an earlier one fails; the script prints a
# summary and exits non-zero if any did.
#
# Usage: LYRIC_BIN=path/to/lyric bash scripts/ci/native-platform-tests.sh
# ---------------------------------------------------------------------------
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

lyric_bin="${LYRIC_BIN:?set LYRIC_BIN to the lyric executable}"
failed=()

run_suite() {
  local label="$1"; shift
  echo "--- $label"
  if "$@"; then :; else
    echo "::error::suite failed: $label"
    failed+=("$label")
  fi
}

echo "=== toolchain ==="
uname -a
clang --version
case "$(uname -s)" in
  Darwin) sw_vers || true; platform=macos ;;
  *) platform=linux ;;
esac

echo "=== lyric-rt (clang) ==="
run_suite "lyric-rt unit tests" make -C lyric-rt test
if [ "$platform" = linux ]; then
  # gcc builds the runtime too, and its AddressSanitizer covers the TLS seam
  # (real loopback OpenSSL handshakes); Apple's cc is clang, so neither applies.
  run_suite "lyric-rt unit tests (gcc)" bash -c 'make -C lyric-rt clean && make -C lyric-rt test CC=gcc'
  run_suite "lyric-rt TLS seam under AddressSanitizer" make -C lyric-rt test-asan CC=gcc
fi

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
  lyric-compiler/lyric/unit_value_self_test.l \
  lyric-compiler/lyric/inline_union_self_test.l \
  lyric-compiler/lyric/generic_ctor_open_arg_self_test.l \
  lyric-compiler/lyric/generic_ctor_widening_self_test.l \
  lyric-compiler/lyric/named_arg_eval_order_self_test.l \
  lyric-compiler/lyric/inout_receiver_self_test.l \
  lyric-compiler/lyric/inout_array_element_self_test.l \
  lyric-compiler/lyric/dot_named_byref_self_test.l \
  lyric-compiler/lyric/dot_named_receivers_self_test.l \
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
  lyric-compiler/lyric/lambda_gaps_batch_self_test.l \
  lyric-compiler/lyric/literal_arg_shape_self_test.l \
  lyric-compiler/lyric/generic_closure_self_test.l \
  lyric-compiler/lyric/generic_member_calls_self_test.l \
  lyric-compiler/lyric/generic_member_calls_std_self_test.l \
  lyric-compiler/lyric/generic_impl_self_test.l \
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
  lyric-compiler/lyric/default_overload_self_test.l \
  lyric-compiler/lyric/covariant_conversion_self_test.l \
  lyric-compiler/lyric/bench_alloc_self_test.l \
  lyric-compiler/lyric/tuple_expected_type_self_test.l \
  lyric-compiler/lyric/expected_type_inference_self_test.l \
  lyric-compiler/lyric/protected_iface_impl_self_test.l \
  lyric-compiler/lyric/generic_protected_self_test.l \
  lyric-compiler/lyric/generic_opaque_self_test.l \
  lyric-compiler/lyric/record_field_closure_self_test.l \
  lyric-compiler/lyric/explicit_type_args_self_test.l \
  lyric-compiler/lyric/protected_iface_impl_self_type_self_test.l \
  lyric-compiler/lyric/byte_native_self_test.l \
  lyric-compiler/lyric/nested_nullary_pattern_native_self_test.l \
  lyric-compiler/lyric/native_enum_pattern_scrutinee_self_test.l \
  lyric-compiler/lyric/extern_cbinding_self_test.l \
  lyric-compiler/lyric/native_stdlib_impl_upcast_self_test.l \
  lyric-compiler/lyric/generic_arg_collection_ctor_self_test.l ; do
  run_suite "$t" "$lyric_bin" test --target native "$t"
done

echo "=== stdlib suites (--target native) ==="
for t in \
  lyric-stdlib/tests/task_native_tests.l \
  lyric-stdlib/tests/secure_random_native_tests.l \
  lyric-stdlib/tests/random_native_tests.l \
  lyric-stdlib/tests/char_native_tests.l \
  lyric-stdlib/tests/path_tests.l \
  lyric-stdlib/tests/directory_tests.l \
  lyric-stdlib/tests/plugin_manifest_tests.l \
  lyric-stdlib/tests/json_native_tests.l \
  lyric-stdlib/tests/json_value_tests.l \
  lyric-stdlib/tests/annotation_meta_native_tests.l \
  lyric-stdlib/tests/linalg_tests.l ; do
  run_suite "$t" "$lyric_bin" test --target native "$t"
done
run_suite "parse_tests" "$lyric_bin" run --target native lyric-stdlib/tests/parse_tests.l

echo "=== compiler-hosted native suites ==="
bash scripts/stage-selfhosted-compiler.sh "$lyric_bin" "$(dirname "$lyric_bin")/lib" || failed+=("stage-selfhosted-compiler")
for t in \
  lyric-compiler/lyric/llvm_ir_self_test.l \
  lyric-compiler/lyric/llvm_codegen_self_test.l \
  lyric-compiler/lyric/llvm_heap_self_test.l \
  lyric-compiler/lyric/llvm_byvalue_record_self_test.l \
  lyric-compiler/lyric/llvm_inline_union_self_test.l \
  lyric-compiler/lyric/llvm_fixed_array_self_test.l \
  lyric-compiler/lyric/llvm_buffer_self_test.l \
  lyric-compiler/lyric/llvm_ffi_self_test.l \
  lyric-compiler/lyric/llvm_c_abi_self_test.l \
  lyric-compiler/lyric/bindgen_self_test.l \
  lyric-compiler/lyric/llvm_collections_self_test.l \
  lyric-compiler/lyric/llvm_stdlib_self_test.l \
  lyric-compiler/lyric/llvm_tls_self_test.l \
  lyric-compiler/lyric/llvm_http_client_self_test.l \
  lyric-compiler/lyric/llvm_http_server_self_test.l \
  lyric-compiler/lyric/llvm_self_test_n3.l \
  lyric-compiler/lyric/llvm_self_test_n34.l \
  lyric-compiler/lyric/llvm_self_test_async.l \
  lyric-compiler/lyric/llvm_self_test_async_mt.l \
  lyric-compiler/lyric/llvm_self_test_defer.l \
  lyric-compiler/lyric/llvm_opaque_self_test.l \
  lyric-compiler/lyric/llvm_enum_case_resolve_self_test.l \
  lyric-compiler/lyric/llvm_inout_self_test.l \
  lyric-compiler/lyric/llvm_project_self_test.l \
  lyric-compiler/lyric/cli_run_native_project_self_test.l \
  lyric-compiler/lyric/fixed_array_project_self_test.l \
  lyric-compiler/lyric/fixed_array_restored_self_test.l \
  lyric-compiler/lyric/native_dependency_self_test.l \
  lyric-compiler/lyric/native_libs_self_test.l \
  lyric-compiler/lyric/native_string_normalize_panic_self_test.l \
  lyric-compiler/lyric/native_missing_stdlib_self_test.l \
  lyric-compiler/lyric/llvm_config_self_test.l \
  lyric-compiler/lyric/llvm_self_test_self_iface.l \
  lyric-compiler/lyric/llvm_self_test_impl_direct.l ; do
  run_suite "$t" env LYRIC_LOAD_COMPILER=1 "$lyric_bin" test "$t"
done

echo "=== end-to-end programs ==="
# #7858, D163, D167: byte printing, the debug/release overflow profile, fixed-array bounds.
run_suite "byte-println-e2e" env LYRIC_BIN="$lyric_bin" bash scripts/ci/byte-println-e2e.sh native
run_suite "overflow-profile-e2e" env LYRIC_BIN="$lyric_bin" bash scripts/ci/overflow-profile-e2e.sh native
run_suite "fixed-array-e2e" env LYRIC_BIN="$lyric_bin" bash scripts/ci/fixed-array-e2e.sh native
# #8031, D169, D173, #8179, #8279: refinement, value generics and inout across packages.
run_suite "range-refinement-e2e" env LYRIC_BIN="$lyric_bin" bash scripts/ci/range-refinement-e2e.sh native
run_suite "value-generic-record-e2e" env LYRIC_BIN="$lyric_bin" bash scripts/ci/value-generic-record-e2e.sh native
run_suite "inout-receiver-e2e" env LYRIC_BIN="$lyric_bin" bash scripts/ci/inout-receiver-e2e.sh native
run_suite "hoisted-callee-cross-package-e2e" env LYRIC_BIN="$lyric_bin" bash scripts/ci/hoisted-callee-cross-package-e2e.sh native

echo "=== summary ==="
if [ "${#failed[@]}" -gt 0 ]; then
  printf 'FAILED: %s\n' "${failed[@]}"
  exit 1
fi
echo "macOS native suite passed"
