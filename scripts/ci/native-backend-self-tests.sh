#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# native-backend-self-tests.sh — build lyric-rt (clang + gcc + ASan) and run
# the `--target native` (LLVM backend) self-test suite through the AOT
# `lyric` binary via LYRIC_LOAD_COMPILER=1.
#
# Extracted from `.github/workflows/ci.yml`'s "native-backend-self-tests"
# job to keep the workflow file under GitHub's undocumented workflow-file
# size ceiling (issue #6781; see scripts/ci/check-workflow-size.sh's header
# for the full story — GitHub silently stops creating runs for an oversized
# workflow, no error, no queued run, no annotation).
#
# Usage: bash scripts/ci/native-backend-self-tests.sh
# (no arguments; the self-test file list is fixed below)
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

BUILD_CONFIG="${BUILD_CONFIG:-Debug}"

if [ ! -d .bootstrap/stage1 ] || [ ! -f .bootstrap/stage1/Lyric.Lyric.Cli.dll ]; then
  echo "::error::stage 1 bundle missing; skipping native backend self-tests"
  exit 1
fi
lyric_bin="bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin; skipping native backend self-tests"
  exit 1
fi
command -v clang >/dev/null || { echo "::error::clang not found on the runner"; exit 1; }
# Other background steps of this job run apt-get too; make every apt-get wait for
# the dpkg lock instead of failing with "Could not get lock" (exit 100).
printf 'DPkg::Lock::Timeout "900";\n' | sudo tee /etc/apt/apt.conf.d/99lyric-ci-lock-timeout >/dev/null
# ASan preflight: the heap self-test links -fsanitize=address. Use $TMPDIR
# (redirected to runner.temp by the job's earlier step), not a hardcoded
# /tmp, so this step doesn't bypass the SIGBUS/resource-pressure mitigation
# the rest of this job relies on (#4975).
echo 'int main(void){return 0;}' > "$TMPDIR/asan_preflight.c"
if ! clang -fsanitize=address "$TMPDIR/asan_preflight.c" -o "$TMPDIR/asan_preflight" 2>/dev/null; then
  sudo apt-get update -qq && sudo apt-get install -y -qq "libclang-rt-$(clang -dumpversion | cut -d. -f1)-dev"
  clang -fsanitize=address "$TMPDIR/asan_preflight.c" -o "$TMPDIR/asan_preflight"
fi
make -C lyric-rt test
make -C lyric-rt clean && make -C lyric-rt test CC=gcc
# ASan run of the TLS transport seam (real loopback OpenSSL handshakes)
# under gcc's reliably-present libasan -- a leaked SSL_CTX/SSL/fd or a
# use-after-free in a handshake round-trip fails the run (issue #5890,
# docs/61 §7).
make -C lyric-rt test-asan CC=gcc
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
  lyric-compiler/lyric/llvm_self_test_self_iface.l \
  lyric-compiler/lyric/llvm_self_test_impl_direct.l ; do
  echo "=== $t ==="
  LYRIC_LOAD_COMPILER=1 "$lyric_bin" test "$t"
done
# Cross-target suites that also run on dotnet/JVM elsewhere in ci.yml; this
# lane covers their native run (#7364 review).
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
  lyric-compiler/lyric/protected_iface_impl_self_test.l \
  lyric-compiler/lyric/generic_protected_self_test.l \
  lyric-compiler/lyric/generic_opaque_self_test.l \
  lyric-compiler/lyric/record_field_closure_self_test.l \
  lyric-compiler/lyric/explicit_type_args_self_test.l \
  lyric-compiler/lyric/protected_iface_impl_self_type_self_test.l \
  lyric-compiler/lyric/byte_native_self_test.l \
  lyric-compiler/lyric/nested_nullary_pattern_native_self_test.l \
  lyric-compiler/lyric/native_enum_pattern_scrutinee_self_test.l \
  lyric-compiler/lyric/extern_cbinding_self_test.l ; do
  echo "=== $t (--target native) ==="
  "$lyric_bin" test --target native "$t"
done
# #7858: the text `println(<Byte>)` writes on native.
LYRIC_BIN="$lyric_bin" bash scripts/ci/byte-println-e2e.sh native
# D163: a debug build panics on integer overflow, a release build wraps.
LYRIC_BIN="$lyric_bin" bash scripts/ci/overflow-profile-e2e.sh native
# D167: an array index outside `0 ..< N` panics with the index and length.
LYRIC_BIN="$lyric_bin" bash scripts/ci/fixed-array-e2e.sh native
# docs/67 G1: Vec3 arithmetic and an inline array of Vec3 allocate nothing.
LYRIC_BIN="$lyric_bin" bash scripts/ci/bench-vec3-alloc.sh
# #8031: an inline range type is checked wherever a value reaches it.
LYRIC_BIN="$lyric_bin" bash scripts/ci/range-refinement-e2e.sh native
# D169, D173: a value-generic record is usable in its own package and from
# another.
LYRIC_BIN="$lyric_bin" bash scripts/ci/value-generic-record-e2e.sh native
# #8179: `inout` receivers and generic `inout` parameters across packages.
LYRIC_BIN="$lyric_bin" bash scripts/ci/inout-receiver-e2e.sh native
# #8279: indexed callees beside `?` and `await` named from another package.
LYRIC_BIN="$lyric_bin" bash scripts/ci/hoisted-callee-cross-package-e2e.sh native
# Std.Task, Std.SecureRandom, Std.Json and Std.JsonValue on native (#8135, #7856):
# the stdlib suites that need no catchable panic.
for t in \
  lyric-stdlib/tests/task_native_tests.l \
  lyric-stdlib/tests/secure_random_native_tests.l \
  lyric-stdlib/tests/random_native_tests.l \
  lyric-stdlib/tests/char_native_tests.l \
  lyric-stdlib/tests/json_native_tests.l \
  lyric-stdlib/tests/json_value_tests.l \
  lyric-stdlib/tests/linalg_tests.l ; do
  echo "=== $t (--target native) ==="
  "$lyric_bin" test --target native "$t"
done
# Std.Parse is a plain program, not a test module.
"$lyric_bin" run --target native lyric-stdlib/tests/parse_tests.l
# docs/67 G6: lyric-text on FreeType and HarfBuzz (shaping, rasterising, fallback, layout, a golden scene).
LYRIC_BIN="$lyric_bin" bash scripts/ci/text-examples-e2e.sh
# docs/67 G8: Std.Parallel and the lyric-rt worker pool (ThreadSanitizer, scaling).
LYRIC_BIN="$lyric_bin" bash scripts/ci/parallel-e2e.sh
# docs/67 G6: lyric-draw on lyric-gpu and lyric-text (a golden scene and a text-heavy frame on lavapipe).
LYRIC_BIN="$lyric_bin" bash scripts/ci/draw-examples-e2e.sh
# docs/67 G5: lyric-gpu's compute and render examples on wgpu-native over lavapipe.
LYRIC_BIN="$lyric_bin" bash scripts/ci/gpu-examples-e2e.sh
# docs/67 G4 + G5: lyric-window on SDL3 and lyric-gpu's surface.  SDL3 is built once from the pinned
# release tarball with its X11 driver (the headless offscreen/dummy/disk drivers stay available);
# the window demo runs headless, the surface example on an Xvfb display with lavapipe.
command -v cmake >/dev/null || sudo apt-get install -y -qq cmake
sudo apt-get install -y -qq libx11-dev libxext-dev libxcursor-dev libxi-dev libxrandr-dev libxfixes-dev \
  libxrender-dev libxtst-dev xvfb x11-apps imagemagick xdotool
sdl3_prefix="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/sdl3"
bash scripts/ci/build-sdl3.sh --x11 "$sdl3_prefix"
LYRIC_BIN="$lyric_bin" SDL3_PREFIX="$sdl3_prefix" bash scripts/ci/window-examples-e2e.sh
LYRIC_BIN="$lyric_bin" SDL3_PREFIX="$sdl3_prefix" bash scripts/ci/gpu-window-e2e.sh
# docs/67 G7: lyric-game's Breakout sample (tests, headless native replay, an X11 window under Xvfb).
LYRIC_BIN="$lyric_bin" SDL3_PREFIX="$sdl3_prefix" bash scripts/ci/game-examples-e2e.sh
# docs/67 G10: the native lyric-ui host on examples/ui-customers (scripted golden frames, then a live X11 window).
LYRIC_BIN="$lyric_bin" SDL3_PREFIX="$sdl3_prefix" bash scripts/ci/ui-native-e2e.sh
