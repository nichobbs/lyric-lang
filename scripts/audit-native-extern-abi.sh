#!/usr/bin/env bash
# Fail when a lyric-stdlib/std/_kernel_native extern disagrees with the C
# definition it binds on the wasm32 ABI (docs/35 W2 slice 3).  Needs a
# wasi-sdk: WASI_SDK_PATH, or scripts/ci/wasm32-wasi-rt-tests.sh's toolchain.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
: "${WASI_SDK_PATH:?set WASI_SDK_PATH to a wasi-sdk install}"
make -C lyric-rt wasm32-wasi-ir WASI_SDK="$WASI_SDK_PATH" >/dev/null
python3 scripts/audit_native_extern_abi.py lyric-stdlib/std/_kernel_native lyric-rt/build-wasm32-wasi/ir
