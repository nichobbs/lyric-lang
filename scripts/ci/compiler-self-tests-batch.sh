#!/usr/bin/env bash
set -euo pipefail
if [ ! -d .bootstrap/stage1 ] || [ ! -f .bootstrap/stage1/Lyric.Lyric.Cli.dll ]; then
  echo "::error::stage 1 bundle missing; skipping compiler self-tests"
  exit 1
fi
lyric_bin="bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin; skipping compiler self-tests"
  exit 1
fi
ran=""
for t in \
  lyric-compiler/lyric/lexer_self_test.l \
  lyric-compiler/lyric/parser_self_test.l \
  lyric-compiler/lyric/typechecker_self_test.l \
  lyric-compiler/lyric/modechecker_self_test.l \
  lyric-compiler/lyric/contract_elaborator_self_test.l \
  lyric-compiler/lyric/cfg_self_test.l \
  lyric-compiler/lyric/cfg_single_file_self_test.l \
  lyric-compiler/lyric/build_defines_self_test.l \
  lyric-compiler/lyric/derives_self_test.l \
  lyric-compiler/lyric/mono_self_test.l \
  lyric-compiler/lyric/result_generic_specialization_self_test.l \
  lyric-compiler/lyric/alias_impl_self_test.l \
  lyric-compiler/lyric/quantifier_ident_self_test.l \
  lyric-compiler/lyric/range_subtype_self_test.l \
  lyric-compiler/lyric/fmt_self_test.l \
  lyric-compiler/lyric/async_generator_self_test.l \
  lyric-compiler/lyric/class_encoding_self_test.l \
  lyric-compiler/lyric/hof_type_propagation_self_test.l \
  lyric-compiler/lyric/typechecker_extern_dedup_self_test.l \
  lyric-compiler/lyric/generic_extern_self_test.l \
  lyric-compiler/lyric/generic_extern_methodspec_self_test.l \
  lyric-compiler/lyric/enum_msil_self_test.l \
  lyric-compiler/lyric/contract_meta_self_test.l \
  lyric-compiler/lyric/restored_packages_self_test.l \
  lyric-compiler/lyric/test_synth_self_test.l \
  lyric-compiler/lyric/manifest_self_test.l \
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
  lyric-compiler/lyric/closure_correctness_self_test.l \
  lyric-compiler/lyric/func_val_local_rettype_self_test.l \
  lyric-compiler/lyric/bare_func_ref_self_test.l \
  lyric-compiler/lyric/qualified_enum_case_self_test.l \
  lyric-compiler/lyric/qualified_union_case_self_test.l \
  lyric-compiler/lyric/slice_append_widening_self_test.l \
  lyric-compiler/lyric/pconstructor_typed_binding_self_test.l \
  lyric-compiler/lyric/nested_constructor_pattern_self_test.l \
  lyric-compiler/lyric/record_omitted_default_self_test.l \
  lyric-compiler/lyric/slice_byte_lambda_arg_self_test.l \
  lyric-compiler/lyric/app_host_self_test.l \
  lyric-compiler/lyric/deflate_zip_self_test.l \
  lyric-compiler/lyric/jvm_lambda_iface_bundling_self_test.l \
  lyric-compiler/lyric/generator/generator_self_test.l \
  lyric-compiler/lyric/jvm_trycatch_bridge_self_test.l \
  lyric-compiler/lyric/jvm_impl_extern_class_self_test.l \
  lyric-compiler/lyric/lsp_self_test.l \
  lyric-compiler/lyric/doc_self_test.l ; do
  echo "=== $t ==="
  bash scripts/ci-retry-on-signal.sh "$lyric_bin" test "$t"
  ran="$ran $t"
done
echo "Compiler self-tests ran:$ran" >> "$GITHUB_STEP_SUMMARY"

