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
ran=""
idx=0
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
  lyric-compiler/lyric/annotation_meta_emit_self_test.l \
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
  idx=$((idx + 1))
  if (( (idx - 1) % SHARD_N != SHARD_K - 1 )); then
    continue
  fi
  echo "=== $t ==="
  bash scripts/ci-retry-on-signal.sh "$lyric_bin" test "$t"
  ran="$ran $t"
done
if [[ -z "$ran" ]]; then
  echo "::error::shard ${SHARD_K}/${SHARD_N} selected no files" >&2
  exit 1
fi
echo "Compiler self-tests (shard ${SHARD_K}/${SHARD_N}) ran:$ran" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

