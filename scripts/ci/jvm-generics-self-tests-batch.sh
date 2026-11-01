#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# jvm-generics-self-tests-batch.sh — run a batch of `--target jvm` self-tests
# covering erased/generic-parameter and cross-package-type resolution gaps
# in `Jvm.Codegen`/`Jvm.Bridge`, plus the JVM half of dual-target runtime
# tests whose dotnet half runs in `compiler-self-tests-batch.sh` (e.g.
# closure_var_capture_self_test.l, #7460;
# closure_captured_var_byref_self_test.l, #8189; the protected-type interface impl
# tests, #7457; bare_func_ref_self_test.l, #7586; async_generator_self_test.l,
# #7720; compiler_bugs_3502_3505_3547_self_test.l, #7752;
# erased_slot_widen_self_test.l, #7782; list_insert_self_test.l, #7797;
# list_literal_join_self_test.l, #7818; tuple_expected_type_self_test.l,
# #7824; await_hoist_typed_self_test.l, #7823;
# expected_type_propagation_self_test.l, #7855;
# generic_ctor_open_arg_self_test.l, #7844; the generic_ctor_*widening
# self-tests, #7813; the overflow self-tests,
# D163; record_eq_self_test.l, D164; task_shadow_self_test.l, D166;
# propagate_ctor_operand_self_test.l and propagate_ctor_operand_try_self_test.l,
# #8181; async_sm_self_test.l, #8294;
# the structural_equality self-tests, D172; slice_func_tolist_self_test.l,
# slice_to_list_self_test.l and int_to_nat_self_test.l, #7661, #7662, #8323;
# jvm_erased_types_self_test.l, #8281, #8237, #8132, #8162, #7298;
# extern_upcast_jvm_self_test.l and jvm-stdlib-type-check-gate.sh, D212;
# match_return_defer_jvm_self_test.l, #7541;
# nested_generic_result_jvm_self_test.l, #8242, #8528;
# lyric-stdlib/tests/http_client_wire_tests.l, #8560;
# for_loop_dispose_extern_jvm_self_test.l, #7770, #8604),
# through one
# `lyric test`
# invocation per file.
#
#   bash scripts/ci/jvm-generics-self-tests-batch.sh
#
# Consolidates several previously-separate one-line CI steps (each its own
# `bash scripts/ci/self-test.sh --target jvm <file>` step) into one, mirroring
# `compiler-self-tests-batch.sh`'s loop-over-a-list shape — ci.yml is near
# GitHub's undocumented size ceiling (`check-workflow-size.sh`), so adding a
# new self-test's CI coverage this way costs one line in this file instead of
# a whole new 6-line step block. A failure in ANY file fails the whole batch
# (no `|| true`), matching what several separate required steps already gave.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

BUILD_CONFIG="${BUILD_CONFIG:-Debug}"
if [ ! -d .bootstrap/stage1 ] || [ ! -f .bootstrap/stage1/Lyric.Lyric.Cli.dll ]; then
  echo "::error::stage 1 bundle missing; skipping JVM generics self-tests" >&2
  exit 1
fi
lyric_bin="bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin; skipping JVM generics self-tests" >&2
  exit 1
fi

ran=""
for t in \
  lyric-stdlib/tests/http_client_wire_tests.l \
  lyric-compiler/jvm/generic_param_field_read_jvm_self_test.l \
  lyric-compiler/lyric/bounded_generic_ops_self_test.l \
  lyric-compiler/lyric/generic_default_named_self_test.l \
  lyric-compiler/lyric/open_alias_self_test.l \
  lyric-compiler/lyric/generic_overload_arity_self_test.l \
  lyric-compiler/lyric/explicit_type_args_checked_self_test.l \
  lyric-compiler/lyric/interface_method_generic_self_test.l \
  lyric-compiler/lyric/self_join_self_test.l \
  lyric-compiler/lyric/method_generic_self_test.l \
  lyric-compiler/lyric/open_receiver_self_test.l \
  lyric-compiler/lyric/generic_member_stdlib_native_self_test.l \
  lyric-compiler/jvm/match_return_defer_jvm_self_test.l \
  lyric-compiler/jvm/nested_generic_result_jvm_self_test.l \
  lyric-compiler/jvm/generic_element_field_read_jvm_self_test.l \
  lyric-compiler/jvm/generic_free_func_return_jvm_self_test.l \
  lyric-compiler/jvm/cross_package_type_resolution_jvm_self_test.l \
  lyric-compiler/jvm/derive_dot_name_mangle_jvm_self_test.l \
  lyric-compiler/jvm/dot_named_mangle_owner_match_jvm_self_test.l \
  lyric-compiler/lyric/async_sm_self_test.l \
  lyric-compiler/lyric/tuple_nullary_case_self_test.l \
  lyric-compiler/lyric/tuple_inbundle_generic_self_test.l \
  lyric-compiler/lyric/closure_unannotated_result_self_test.l \
  lyric-compiler/lyric/lambda_field_ctor_arg_self_test.l \
  lyric-compiler/lyric/closure_var_capture_self_test.l \
  lyric-compiler/lyric/closure_captured_var_byref_self_test.l \
  lyric-compiler/lyric/closure_shadow_self_test.l \
  lyric-compiler/lyric/lambda_gaps_batch_self_test.l \
  lyric-compiler/lyric/generic_closure_self_test.l \
  lyric-compiler/lyric/generic_member_calls_self_test.l \
  lyric-compiler/lyric/generic_member_calls_std_self_test.l \
  lyric-compiler/lyric/generic_impl_self_test.l \
  lyric-compiler/lyric/generic_protected_calls_self_test.l \
  lyric-compiler/lyric/inout_receiver_self_test.l \
  lyric-compiler/lyric/inout_receiver_closure_self_test.l \
  lyric-compiler/lyric/inout_array_element_self_test.l \
  lyric-compiler/lyric/dot_named_byref_self_test.l \
  lyric-compiler/lyric/dot_named_receivers_self_test.l \
  lyric-compiler/lyric/dot_named_primitive_self_test.l \
  lyric-compiler/lyric/type_qualified_method_self_test.l \
  lyric-compiler/lyric/member_local_shadow_self_test.l \
  lyric-compiler/lyric/member_local_shadow_panics_self_test.l \
  lyric-compiler/lyric/propagate_ctor_operand_self_test.l \
  lyric-compiler/lyric/propagate_never_value_self_test.l \
  lyric-compiler/lyric/propagate_ctor_operand_try_self_test.l \
  lyric-compiler/lyric/protected_byref_self_test.l \
  lyric-compiler/lyric/inout_aliasing_self_test.l \
  lyric-compiler/lyric/inout_aliasing_closure_self_test.l \
  lyric-compiler/lyric/inout_loop_cache_self_test.l \
  lyric-compiler/lyric/hoisted_literal_shape_self_test.l \
  lyric-compiler/lyric/literal_arg_shape_self_test.l \
  lyric-compiler/lyric/inout_array_element_try_self_test.l \
  lyric-compiler/lyric/method_closure_var_capture_self_test.l \
  lyric-compiler/lyric/nested_lambda_var_capture_self_test.l \
  lyric-compiler/lyric/generic_record_var_field_self_test.l \
  lyric-compiler/lyric/bare_func_ref_self_test.l \
  lyric-compiler/lyric/unit_func_ref_action_self_test.l \
  lyric-compiler/lyric/inout_self_param_self_test.l \
  lyric-compiler/lyric/union_named_arg_order_self_test.l \
  lyric-compiler/lyric/local_as_pattern_self_test.l \
  lyric-compiler/lyric/record_method_option_param_self_test.l \
  lyric-compiler/lyric/string_split_intrinsic_self_test.l \
  lyric-compiler/lyric/impl_self_spelling_self_test.l \
  lyric-compiler/lyric/protected_iface_impl_self_test.l \
  lyric-compiler/lyric/generic_protected_self_test.l \
  lyric-compiler/lyric/generic_opaque_self_test.l \
  lyric-compiler/lyric/config_block_no_env_import_self_test.l \
  lyric-compiler/lyric/config_override_self_test.l \
  lyric-compiler/lyric/protected_iface_impl_contracts_self_test.l \
  lyric-compiler/lyric/protected_iface_impl_self_type_self_test.l \
  lyric-compiler/lyric/protected_iface_impl_self_type_nested_self_test.l \
  lyric-compiler/lyric/contract_generic_call_self_test.l \
  lyric-compiler/lyric/contract_fall_off_ensures_self_test.l \
  lyric-compiler/lyric/module_val_destructure_self_test.l \
  lyric-compiler/lyric/return_list_literal_self_test.l \
  lyric-compiler/lyric/compiler_bugs_3502_3505_3547_self_test.l \
  lyric-compiler/jvm/static_type_recovery_jvm_self_test.l \
  lyric-compiler/jvm/curried_generic_union_jvm_self_test.l \
  lyric-compiler/jvm/propagate_dot_named_bind_jvm_self_test.l \
  lyric-compiler/lyric/inbundle_generic_method_typevar_default_self_test.l \
  lyric-compiler/lyric/generic_method_body_typevar_self_test.l \
  lyric-compiler/lyric/impl_generic_target_self_test.l \
  lyric-compiler/lyric/generator_closure_var_capture_self_test.l \
  lyric-compiler/lyric/generator_for_loop_self_test.l \
  lyric-compiler/lyric/tuple_pattern_binding_self_test.l \
  lyric-compiler/lyric/generator_element_type_self_test.l \
  lyric-compiler/lyric/generator_callee_resolution_self_test.l \
  lyric-compiler/lyric/local_union_case_shadow_self_test.l \
  lyric-compiler/lyric/async_generator_self_test.l \
  lyric-compiler/lyric/generator_control_flow_self_test.l \
  lyric-compiler/lyric/generator_dispose_self_test.l \
  lyric-compiler/lyric/for_loop_dispose_enumerable_self_test.l \
  lyric-compiler/lyric/for_loop_dispose_extern_jvm_self_test.l \
  lyric-compiler/lyric/async_for_loop_suspend_self_test.l \
  lyric-compiler/lyric/async_match_suspend_self_test.l \
  lyric-compiler/lyric/method_default_args_self_test.l \
  lyric-compiler/lyric/default_overload_self_test.l \
  lyric-compiler/lyric/covariant_conversion_self_test.l \
  lyric-compiler/lyric/method_default_widening_self_test.l \
  lyric-compiler/lyric/erased_receiver_narrowing_self_test.l \
  lyric-compiler/lyric/unannotated_list_result_self_test.l \
  lyric-compiler/lyric/erased_slot_widen_self_test.l \
  lyric-compiler/lyric/list_insert_self_test.l \
  lyric-compiler/lyric/list_literal_join_self_test.l \
  lyric-compiler/lyric/tuple_expected_type_self_test.l \
  lyric-compiler/lyric/expected_type_inference_self_test.l \
  lyric-compiler/lyric/await_hoist_typed_self_test.l \
  lyric-compiler/lyric/expected_type_propagation_self_test.l \
  lyric-compiler/lyric/generic_ctor_open_arg_self_test.l \
  lyric-compiler/lyric/generic_ctor_widening_self_test.l \
  lyric-compiler/lyric/named_arg_eval_order_self_test.l \
  lyric-compiler/lyric/branch_binding_ctor_type_self_test.l \
  lyric-compiler/lyric/generic_ctor_unsigned_widening_self_test.l \
  lyric-compiler/lyric/overflow_self_test.l \
  lyric-compiler/lyric/overflow_panic_self_test.l \
  lyric-compiler/lyric/fixed_array_self_test.l \
  lyric-compiler/lyric/value_generic_record_self_test.l \
  lyric-compiler/lyric/value_generic_protected_self_test.l \
  lyric-compiler/lyric/dotted_generic_func_self_test.l \
  lyric-compiler/lyric/structural_equality_self_test.l \
  lyric-compiler/lyric/structural_equality_collections_self_test.l \
  lyric-compiler/lyric/stdlib_parity_self_test.l \
  lyric-compiler/lyric/fixed_array_panic_self_test.l \
  lyric-compiler/lyric/buffer_self_test.l \
  lyric-compiler/lyric/buffer_spawn_self_test.l \
  lyric-compiler/lyric/buffer_panic_self_test.l \
  lyric-compiler/lyric/bench_alloc_self_test.l \
  lyric-compiler/lyric/record_eq_self_test.l \
  lyric-compiler/lyric/task_shadow_self_test.l \
  lyric-compiler/lyric/task_kernel_record_self_test.l \
  lyric-compiler/lyric/byvalue_record_self_test.l \
  lyric-compiler/lyric/unit_value_self_test.l \
  lyric-compiler/lyric/inline_union_self_test.l \
  lyric-compiler/lyric/unsigned_typed_ops_self_test.l \
  lyric-compiler/lyric/unsigned_literal_max_self_test.l \
  lyric-compiler/lyric/signed_literal_suffix_range_self_test.l \
  lyric-compiler/lyric/byte_stringify_self_test.l \
  lyric-compiler/lyric/byte_arithmetic_self_test.l \
  lyric-compiler/lyric/option_match_self_test.l \
  lyric-compiler/lyric/format_builtin_self_test.l \
  lyric-compiler/lyric/byte_erased_positions_self_test.l \
  lyric-compiler/lyric/function_value_typing_self_test.l \
  lyric-compiler/lyric/byref_value_type_self_test.l \
  lyric-compiler/lyric/slice_func_elem_self_test.l \
  lyric-compiler/lyric/slice_func_unit_elem_self_test.l \
  lyric-compiler/lyric/slice_func_tolist_self_test.l \
  lyric-compiler/lyric/slice_to_list_self_test.l \
  lyric-compiler/lyric/int_to_nat_self_test.l \
  lyric-compiler/lyric/jvm_erased_types_self_test.l \
  lyric-compiler/lyric/println_stringify_self_test.l \
  lyric-compiler/lyric/structural_tostring_self_test.l \
  lyric-compiler/lyric/println_extern_jvm_self_test.l \
  lyric-compiler/lyric/extern_upcast_jvm_self_test.l ; do
  echo "=== $t ==="
  "$lyric_bin" test --target jvm "$t"
  ran="$ran $t"
done
# Stdlib suites written as programs (`func main`) rather than `@test_module`s:
# Std.Encoding's `Option[slice[Byte]]` specialisation (a VerifyError until
# #8441) and Std.Xml (once thought not to compile on the JVM), #7511.
for t in lyric-stdlib/tests/encoding_tests.l lyric-stdlib/tests/xml_tests.l ; do
  echo "=== $t (run) ==="
  "$lyric_bin" run --target jvm "$t"
  ran="$ran $t"
done
# A numeric `array[N, T]` is a typed Java array that boxes nothing (#8041).
bash scripts/ci/jvm-typed-arrays-nobox.sh "$lyric_bin"
# A bundled stdlib package is type-checked, and a type error stops the build (#7976).
LYRIC_BIN="$lyric_bin" bash scripts/ci/jvm-stdlib-type-check-gate.sh
echo "JVM generics self-tests ran:$ran" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
