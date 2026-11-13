#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# native-via-tir-census.sh - the native self-tests that build through the real
# pipeline, run with the TIR lowering on (docs/70 §12.2, phase 4a, D520).
#
# `LYRIC_NATIVE_VIA_TIR=1` makes every native build in these suites lower the
# functions TIR covers from TIR (own packages and the bundled standard library)
# and keep the rest on the AST path, so a function TIR lowers differently from
# the AST path fails the suite that exercises it.  Suites that call
# `codegenNativePackage` on a parsed file skip the middle end and cannot reach
# TIR; they move to the bridge pipeline when the AST entry is deleted.
#
# Known gaps are listed below with their tracking issue; a suite is removed from
# the list only when its issue is fixed, never to make a run green.
#
# Usage: LYRIC_BIN=<lyric> bash scripts/ci/native-via-tir-census.sh
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
lyric_bin="${LYRIC_BIN:-./bin/lyric}"

export LYRIC_NATIVE_VIA_TIR=1

# Test modules that import compiler packages.
for t in \
  lyric-compiler/lyric/llvm_invariant_boundary_self_test.l \
  lyric-compiler/lyric/llvm_collections_self_test.l \
  lyric-compiler/lyric/llvm_stdlib_self_test.l ; do
  echo "=== $t (via TIR) ==="
  LYRIC_LOAD_COMPILER=1 "$lyric_bin" test "$t"
done

# Cross-target suites, built for native.
# Not listed: named_arg_eval_order_self_test.l - the TIR call build reads a plain local after a later
# argument's inout call changed it (nichobbs/lyric-lang#9076).
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
  lyric-compiler/lyric/inout_receiver_self_test.l \
  lyric-compiler/lyric/inout_array_element_self_test.l \
  lyric-stdlib/tests/annotation_meta_native_tests.l \
  lyric-stdlib/tests/linalg_tests.l ; do
  echo "=== $t (--target native, via TIR) ==="
  "$lyric_bin" test --target native "$t"
done
echo "native-via-tir-census: ok"
