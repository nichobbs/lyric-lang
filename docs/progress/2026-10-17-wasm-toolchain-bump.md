# wasm32 toolchain bump: wasi-sdk 34, wasmtime 49.0.3, wasm-tools 1.262.0, jco 1.39.0

`scripts/ci/wasm32-wasi-rt-tests.sh` now pins wasi-sdk 34 (clang 23.1.0),
wasmtime 49.0.3 and its preview1 reactor adapter, wasm-tools 1.262.0, jco 1.39.0
and preview2-shim 0.30.0 (from wasi-sdk 24, wasmtime 26.0.1, wasm-tools 1.220.0,
jco 1.8.1, preview2-shim 0.17.1), with the SHA-256s re-derived from fresh
downloads. The older wasm-tools and wasmtime reject Component Model async
(WASI 0.3), which the component-shape async work needs; see
`docs/progress/2026-10-17-component-async-spike.md`.

Three fixes the new toolchain needed, each also valid on the old one:

- `lyric-rt/Makefile` builds the wasm32 runtime with `--target=wasm32-wasip1`:
  clang 23 deprecates `wasm32-wasi`, an error under the runtime's `-Werror`.
- `--triple wasm32-wasi` now normalises to `wasm32-unknown-wasip1`
  (`llvm_bridge.l`): wasi-sdk 34's sysroot only carries headers under the
  `wasip1` name, so the component shape's generated C failed to find
  `stdlib.h`. The user-facing triple is unchanged.
- The coroutine epilogue calls `llvm.coro.end` without naming its result
  (`llvm_codegen.l`; an empty `NCall` `dest` renders an unnamed call in
  `llvm_ir.l`). LLVM 23 made the intrinsic return `void` and auto-upgrades
  older calls, which left the named `i1` result invalid
  (`Instruction has a name, but provides a void value!`) for any async
  function. The declaration stays `i1`, which LLVM 18 requires.

Verified locally: the whole CI script run end to end against a fresh tool cache
(every download's SHA-256, the runtime unit tests under wasmtime 49, the extern
ABI audit with 0 mismatches, `llvm_wasm32_self_test.l` 11/11,
`llvm_wasm32_module_self_test.l` 32/32, `cli_wasm_npm_project_self_test.l` 6/6,
`llvm_wasm32_component_self_test.l` 24/24, `memfs_test.mjs` 23/23); the module
and component suites and the runtime tests still pass on the old pins with the
three fixes; a host `--target native` async program built by clang 18 runs
correctly. The host ASan suites could not link in the sandbox (no
`libclang_rt.asan_static`) and are left to CI.
