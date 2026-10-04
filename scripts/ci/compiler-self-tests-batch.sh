#!/usr/bin/env bash
# Run the self-hosted compiler `@test_module` corpus through `lyric test`.
#
#   scripts/ci/compiler-self-tests-batch.sh [--shard K/N]
#
# --shard K/N runs only every N-th file starting at the K-th (1-based,
# interleaved like scripts/run-numbered-self-tests.sh), so CI can split the
# corpus across parallel matrix jobs.
set -euo pipefail
SHARD_K=1
SHARD_N=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --shard)
      shard="${2:?--shard needs K/N}"
      if [[ "$shard" != */* ]]; then
        echo "::error::invalid --shard ${shard}; expected K/N with 1 <= K <= N" >&2
        exit 2
      fi
      SHARD_K="${shard%/*}"
      SHARD_N="${shard#*/}"
      shift 2
      ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
if ! [[ "$SHARD_K" =~ ^[0-9]+$ && "$SHARD_N" =~ ^[0-9]+$ ]] || (( SHARD_N < 1 || SHARD_K < 1 || SHARD_K > SHARD_N )); then
  echo "::error::invalid --shard ${SHARD_K}/${SHARD_N}; expected K/N with 1 <= K <= N" >&2
  exit 2
fi
if [ ! -d .bootstrap/stage1 ] || [ ! -f .bootstrap/stage1/Lyric.Lyric.Cli.dll ]; then
  echo "::error::stage 1 bundle missing; skipping compiler self-tests"
  exit 1
fi
lyric_bin="bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin; skipping compiler self-tests"
  exit 1
fi
# cli_restore_self_test.l restores an NPM package with each package manager the
# `[npm.options] manager` setting accepts; npm ships with node, so pin the other
# two beside it.
npm_pm_tools="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/npm-package-managers"
if [ ! -x "$npm_pm_tools/node_modules/.bin/pnpm" ] || [ ! -x "$npm_pm_tools/node_modules/.bin/yarn" ]; then
  mkdir -p "$npm_pm_tools"
  npm install --prefix "$npm_pm_tools" --no-audit --no-fund pnpm@10.28.0 yarn@1.22.22 >/dev/null
fi
export PATH="$npm_pm_tools/node_modules/.bin:$PATH"
ran=""
idx=0
for t in \
  lyric-compiler/lyric/lexer_self_test.l \
  lyric-compiler/lyric/parser_self_test.l \
  lyric-compiler/lyric/typechecker_self_test.l \
  lyric-compiler/lyric/modechecker_self_test.l \
  lyric-compiler/lyric/contract_elaborator_self_test.l \
  lyric-compiler/lyric/contract_generic_call_self_test.l \
  lyric-compiler/lyric/contract_fall_off_ensures_self_test.l \
  lyric-compiler/lyric/module_val_destructure_self_test.l \
  lyric-compiler/lyric/cfg_self_test.l \
  lyric-compiler/lyric/cfg_single_file_self_test.l \
  lyric-compiler/lyric/lint_self_test.l \
  lyric-compiler/lyric/build_defines_self_test.l \
  lyric-compiler/lyric/derives_self_test.l \
  lyric-compiler/lyric/mono_self_test.l \
  lyric-compiler/lyric/result_generic_specialization_self_test.l \
  lyric-compiler/lyric/alias_impl_self_test.l \
  lyric-compiler/lyric/protected_iface_impl_self_test.l \
  lyric-compiler/lyric/generic_protected_self_test.l \
  lyric-compiler/lyric/config_block_no_env_import_self_test.l \
  lyric-compiler/lyric/protected_iface_impl_contracts_self_test.l \
  lyric-compiler/lyric/protected_iface_impl_self_type_self_test.l \
  lyric-compiler/lyric/protected_iface_impl_self_type_nested_self_test.l \
  lyric-compiler/lyric/quantifier_ident_self_test.l \
  lyric-compiler/lyric/range_subtype_self_test.l \
  lyric-compiler/lyric/fmt_self_test.l \
  lyric-compiler/lyric/async_generator_self_test.l \
  lyric-compiler/lyric/generator_closure_var_capture_self_test.l \
  lyric-compiler/lyric/generator_for_loop_self_test.l \
  lyric-compiler/lyric/tuple_pattern_binding_self_test.l \
  lyric-compiler/lyric/generator_element_type_self_test.l \
  lyric-compiler/lyric/generator_callee_resolution_self_test.l \
  lyric-compiler/lyric/local_union_case_shadow_self_test.l \
  lyric-compiler/lyric/generator_control_flow_self_test.l \
  lyric-compiler/lyric/generator_control_flow_dotnet_self_test.l \
  lyric-compiler/lyric/generator_dispose_self_test.l \
  lyric-compiler/lyric/async_for_loop_suspend_self_test.l \
  lyric-compiler/lyric/async_match_suspend_self_test.l \
  lyric-compiler/lyric/method_default_args_self_test.l \
  lyric-compiler/lyric/erased_receiver_narrowing_self_test.l \
  lyric-compiler/lyric/erased_receiver_narrowing_dotnet_self_test.l \
  lyric-compiler/lyric/unannotated_list_result_self_test.l \
  lyric-compiler/lyric/class_encoding_self_test.l \
  lyric-compiler/lyric/hof_type_propagation_self_test.l \
  lyric-compiler/lyric/typechecker_extern_dedup_self_test.l \
  lyric-compiler/lyric/union_case_collision_self_test.l \
  lyric-compiler/lyric/generic_extern_self_test.l \
  lyric-compiler/lyric/generic_extern_methodspec_self_test.l \
  lyric-compiler/lyric/generic_extern_param_self_test.l \
  lyric-compiler/lyric/auto_ffi_generic_setter_self_test.l \
  lyric-compiler/lyric/enum_msil_self_test.l \
  lyric-compiler/lyric/contract_meta_self_test.l \
  lyric-compiler/lyric/annotation_meta_emit_self_test.l \
  lyric-compiler/lyric/restored_packages_self_test.l \
  lyric-compiler/lyric/restored_stdlib_async_self_test.l \
  lyric-compiler/lyric/test_synth_self_test.l \
  lyric-compiler/lyric/manifest_self_test.l \
  lyric-compiler/lyric/layers_self_test.l \
  lyric-compiler/lyric/cli_restore_self_test.l \
  lyric-compiler/lyric/cli_version_self_test.l \
  lyric-compiler/lyric/version_self_test.l \
  lyric-compiler/lyric/cli_workspace_builder_self_test.l \
  lyric-compiler/lyric/cli_build_self_test.l \
  lyric-compiler/lyric/native_image_self_test.l \
  lyric-compiler/lyric/cli_shared_self_test.l \
  lyric-compiler/lyric/cli_copydll_self_test.l \
  lyric-compiler/lyric/cli_publish_self_test.l \
  lyric-compiler/lyric/verifier_self_test.l \
  lyric-compiler/lyric/return_list_literal_self_test.l \
  lyric-compiler/lyric/closure_unannotated_result_self_test.l \
  lyric-compiler/lyric/lambda_field_ctor_arg_self_test.l \
  lyric-compiler/lyric/closure_correctness_self_test.l \
  lyric-compiler/lyric/closure_var_capture_self_test.l \
  lyric-compiler/lyric/compiler_bugs_3502_3505_3547_self_test.l \
  lyric-compiler/lyric/method_closure_var_capture_self_test.l \
  lyric-compiler/lyric/nested_lambda_var_capture_self_test.l \
  lyric-compiler/lyric/generic_record_var_field_self_test.l \
  lyric-compiler/lyric/func_val_local_rettype_self_test.l \
  lyric-compiler/lyric/extern_delegate_value_dotnet_self_test.l \
  lyric-compiler/lyric/bare_func_ref_self_test.l \
  lyric-compiler/lyric/unit_func_ref_action_self_test.l \
  lyric-compiler/lyric/inout_self_param_self_test.l \
  lyric-compiler/lyric/qualified_enum_case_self_test.l \
  lyric-compiler/lyric/qualified_union_case_self_test.l \
  lyric-compiler/lyric/slice_append_widening_self_test.l \
  lyric-compiler/lyric/erased_slot_widen_self_test.l \
  lyric-compiler/lyric/list_insert_self_test.l \
  lyric-compiler/lyric/list_literal_join_self_test.l \
  lyric-compiler/lyric/tuple_expected_type_self_test.l \
  lyric-compiler/lyric/await_hoist_typed_self_test.l \
  lyric-compiler/lyric/expected_type_propagation_self_test.l \
  lyric-compiler/lyric/generic_ctor_open_arg_self_test.l \
  lyric-compiler/lyric/overflow_self_test.l \
  lyric-compiler/lyric/overflow_panic_self_test.l \
  lyric-compiler/lyric/fixed_array_self_test.l \
  lyric-compiler/lyric/fixed_array_panic_self_test.l \
  lyric-compiler/lyric/bench_alloc_self_test.l \
  lyric-compiler/lyric/record_eq_self_test.l \
  lyric-compiler/lyric/task_shadow_self_test.l \
  lyric-compiler/lyric/task_kernel_record_self_test.l \
  lyric-compiler/lyric/byvalue_record_self_test.l \
  lyric-compiler/lyric/inline_union_self_test.l \
  lyric-compiler/lyric/byte_stringify_self_test.l \
  lyric-compiler/lyric/format_builtin_self_test.l \
  lyric-compiler/lyric/byte_erased_positions_self_test.l \
  lyric-compiler/lyric/function_value_typing_self_test.l \
  lyric-compiler/lyric/println_stringify_self_test.l \
  lyric-compiler/lyric/println_extern_struct_dotnet_self_test.l \
  lyric-compiler/lyric/pconstructor_typed_binding_self_test.l \
  lyric-compiler/lyric/nested_constructor_pattern_self_test.l \
  lyric-compiler/lyric/tuple_nullary_case_self_test.l \
  lyric-compiler/lyric/record_omitted_default_self_test.l \
  lyric-compiler/lyric/slice_byte_lambda_arg_self_test.l \
  lyric-compiler/lyric/app_host_self_test.l \
  lyric-compiler/lyric/deflate_zip_self_test.l \
  lyric-compiler/lyric/jvm_lambda_iface_bundling_self_test.l \
  lyric-compiler/lyric/generator/generator_self_test.l \
  lyric-compiler/lyric/jvm_trycatch_bridge_self_test.l \
  lyric-compiler/lyric/jvm_impl_extern_class_self_test.l \
  lyric-compiler/jvm/static_type_recovery_jvm_self_test.l \
  lyric-compiler/jvm/propagate_dot_named_bind_jvm_self_test.l \
  lyric-compiler/lyric/lsp_self_test.l \
  lyric-compiler/lyric/doc_self_test.l \
  lyric-compiler/lyric/inbundle_generic_method_typevar_default_self_test.l \
  lyric-compiler/lyric/generic_method_body_typevar_self_test.l \
  lyric-compiler/lyric/impl_generic_target_self_test.l \
  lyric-compiler/lyric/unsigned_typed_ops_self_test.l \
  lyric-compiler/lyric/unsigned_literal_max_self_test.l \
  lyric-compiler/lyric/signed_literal_suffix_range_self_test.l ; do
  idx=$((idx + 1))
  if (( (idx - 1) % SHARD_N != SHARD_K - 1 )); then
    continue
  fi
  echo "=== $t ==="
  bash scripts/ci-retry-on-signal.sh "$lyric_bin" test "$t"
  ran="$ran $t"
done
# #7481: `@cfg` on individual `test`/`property` items, end to end through the
# CLI (manifest + single-file, dotnet + jvm; this job has Java 21).  Sharded
# like one more corpus entry so exactly one shard runs it.
idx=$((idx + 1))
if (( (idx - 1) % SHARD_N == SHARD_K - 1 )); then
  echo "=== scripts/ci/cfg-gated-test-items-e2e.sh ==="
  LYRIC_BIN="$lyric_bin" bash scripts/ci/cfg-gated-test-items-e2e.sh
  ran="$ran cfg-gated-test-items-e2e"
fi
# #7548: package-qualified distinct-factory call (`Pkg.Type.tryFrom(x)`),
# both targets (this job already has Java 21, same as cfg-gated-test-items-e2e.sh).
idx=$((idx + 1))
if (( (idx - 1) % SHARD_N == SHARD_K - 1 )); then
  echo "=== scripts/ci/distinct-factory-import-e2e.sh ==="
  LYRIC_BIN="$lyric_bin" bash scripts/ci/distinct-factory-import-e2e.sh
  ran="$ran distinct-factory-import-e2e"
fi
# #7583: an unimported qualified reference into another PROJECT package
# (value read / type annotation / call) must report T0020 on BOTH targets in
# a multi-package manifest build, and the imported forms must still build
# and run correctly (this job has Java 21, same precedent as the two e2e
# scripts above).
idx=$((idx + 1))
if (( (idx - 1) % SHARD_N == SHARD_K - 1 )); then
  echo "=== scripts/ci/project-package-import-reachability-e2e.sh ==="
  LYRIC_BIN="$lyric_bin" bash scripts/ci/project-package-import-reachability-e2e.sh
  ran="$ran project-package-import-reachability-e2e"
fi
# #7502: a @generate(Json) record's derive-synthesised `fromJson` called
# from a DIFFERENT project package, on both targets (this job has Java 21,
# same precedent as the e2e scripts above).
idx=$((idx + 1))
if (( (idx - 1) % SHARD_N == SHARD_K - 1 )); then
  echo "=== scripts/ci/derive-json-cross-package-jvm-e2e.sh ==="
  LYRIC_BIN="$lyric_bin" bash scripts/ci/derive-json-cross-package-jvm-e2e.sh
  ran="$ran derive-json-cross-package-jvm-e2e"
fi
# #7852: the text `println(<Byte>)` writes, both targets (this job has Java
# 21, same precedent as the e2e scripts above).
idx=$((idx + 1))
if (( (idx - 1) % SHARD_N == SHARD_K - 1 )); then
  echo "=== scripts/ci/byte-println-e2e.sh ==="
  LYRIC_BIN="$lyric_bin" bash scripts/ci/byte-println-e2e.sh
  ran="$ran byte-println-e2e"
fi
# D163: integer overflow panics in a debug build and wraps in a release build,
# both targets (Java 21, as above).
idx=$((idx + 1))
if (( (idx - 1) % SHARD_N == SHARD_K - 1 )); then
  echo "=== scripts/ci/overflow-profile-e2e.sh ==="
  LYRIC_BIN="$lyric_bin" bash scripts/ci/overflow-profile-e2e.sh dotnet jvm
  ran="$ran overflow-profile-e2e"
fi
# D167: an array index outside `0 ..< N` panics with the index and length,
# both targets (Java 21, as above).
idx=$((idx + 1))
if (( (idx - 1) % SHARD_N == SHARD_K - 1 )); then
  echo "=== scripts/ci/fixed-array-e2e.sh ==="
  LYRIC_BIN="$lyric_bin" bash scripts/ci/fixed-array-e2e.sh dotnet jvm
  ran="$ran fixed-array-e2e"
fi
# #7858: `println(x)` writes what `toString(x)` returns for records, lists,
# extern structs and extern objects, on both targets (Java 21, as above).
idx=$((idx + 1))
if (( (idx - 1) % SHARD_N == SHARD_K - 1 )); then
  echo "=== scripts/ci/println-stringify-e2e.sh ==="
  LYRIC_BIN="$lyric_bin" bash scripts/ci/println-stringify-e2e.sh
  ran="$ran println-stringify-e2e"
fi
if [[ -z "$ran" ]]; then
  echo "::error::shard ${SHARD_K}/${SHARD_N} selected no files" >&2
  exit 1
fi
echo "Compiler self-tests (shard ${SHARD_K}/${SHARD_N}) ran:$ran" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

