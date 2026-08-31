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
  lyric-compiler/lyric/llvm_ffi_self_test.l \
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
  lyric-compiler/lyric/llvm_inout_self_test.l ; do
  echo "=== $t ==="
  LYRIC_LOAD_COMPILER=1 "$lyric_bin" test "$t"
done
