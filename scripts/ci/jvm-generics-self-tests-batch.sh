#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# jvm-generics-self-tests-batch.sh — run a batch of `--target jvm` self-tests
# covering erased/generic-parameter and cross-package-type resolution gaps
# in `Jvm.Codegen`/`Jvm.Bridge`, plus the JVM half of dual-target runtime
# tests whose dotnet half runs in `compiler-self-tests-batch.sh` (e.g.
# closure_var_capture_self_test.l, #7460; the protected-type interface impl
# tests, #7457; bare_func_ref_self_test.l, #7586), through one `lyric test`
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
  lyric-compiler/jvm/generic_param_field_read_jvm_self_test.l \
  lyric-compiler/jvm/generic_element_field_read_jvm_self_test.l \
  lyric-compiler/jvm/generic_free_func_return_jvm_self_test.l \
  lyric-compiler/jvm/cross_package_type_resolution_jvm_self_test.l \
  lyric-compiler/jvm/derive_dot_name_mangle_jvm_self_test.l \
  lyric-compiler/jvm/dot_named_mangle_owner_match_jvm_self_test.l \
  lyric-compiler/lyric/tuple_nullary_case_self_test.l \
  lyric-compiler/lyric/closure_var_capture_self_test.l \
  lyric-compiler/lyric/method_closure_var_capture_self_test.l \
  lyric-compiler/lyric/impl_method_closure_var_capture_self_test.l \
  lyric-compiler/lyric/generic_record_var_field_self_test.l \
  lyric-compiler/lyric/bare_func_ref_self_test.l \
  lyric-compiler/lyric/protected_iface_impl_self_test.l \
  lyric-compiler/lyric/config_block_no_env_import_self_test.l \
  lyric-compiler/lyric/protected_iface_impl_contracts_self_test.l \
  lyric-compiler/lyric/protected_iface_impl_self_type_self_test.l \
  lyric-compiler/lyric/protected_iface_impl_self_type_nested_self_test.l \
  lyric-compiler/lyric/contract_generic_call_self_test.l \
  lyric-compiler/lyric/return_list_literal_self_test.l \
  lyric-compiler/jvm/static_type_recovery_jvm_self_test.l \
  lyric-compiler/jvm/propagate_dot_named_bind_jvm_self_test.l \
  lyric-compiler/lyric/inbundle_generic_method_typevar_default_self_test.l ; do
  echo "=== $t ==="
  "$lyric_bin" test --target jvm "$t"
  ran="$ran $t"
done
echo "JVM generics self-tests ran:$ran" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
