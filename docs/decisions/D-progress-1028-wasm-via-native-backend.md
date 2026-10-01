# D-progress-1028 — WebAssembly target via the native backend, not .NET WASI

**Status:** accepted (specified; not yet implemented - phases W0-W5 in `docs/35`)

Backs `docs/35-js-wasm-component-sketch.md` (rewritten 2026-10) and resolves
its Q-JS-001, Q-JS-003 and Q-JS-005. Supersedes the .NET `wasi-wasm` premise
of the original docs/35 sketch.

## Context

The original docs/35 assumed WASM would come from `dotnet publish -r wasi-wasm`.
Since then the LLVM native backend (D-N-001..D-N-017) has shipped, and
`docs/65` §13.1 and `docs/67` already assume `native -> wasm32`. A 2026-10
audit of the native backend and `lyric-rt` for wasm32 found a toolchain,
runtime and ABI-layout job, not a codegen rewrite.

## Decision

1. **Route.** WASM is the native (LLVM) backend retargeted to the
   `wasm32-wasi` and `wasm32-unknown-unknown` triples, built with a pinned
   wasi-sdk. The .NET WASI route is dropped (runtime and GC size, an
   experimental runtime pack, no WebGPU path). A TypeScript transpilation
   target remains rejected (docs/35 §3.2).
2. **Two output shapes from one code generator.** `--shape module` (core
   wasm plus JS glue, browser UI and WebGPU) is delivered first;
   `--shape component` (WASI Component plus WIT, jco/wasmtime) follows. They
   are additional triple-gated values on the `docs/63` shape axis.
3. **Single-threaded v1** (Q-JS-001). `protected type` is allowed
   internally as a re-entrancy-counter lock and rejected on the export
   surface (E0050). A blocking acquire on a held lock panics. Threads are a
   later profile (Q-JS-009).
4. **`@proof_required` is downgraded to `@runtime_checked`** on wasm builds by
   default; `[wasm] strict = true` makes it a compile error (Q-JS-003).
5. **Testing** (Q-JS-005) runs the wasm artifact under wasmtime or node in a
   dedicated lane; ASan does not apply.
6. **Unavailable capabilities** (process spawn, sockets, TLS, HTTP server)
   get wasm twins under `_kernel_native/` that return defined errors; they
   never fail at link time.
7. **Phase order.** W0 layout hardening (target-neutral, own PR), W1 32-bit
   `Float` (`docs/67` G1, separate work stream, gates the component type
   mapping), W2 `wasm32-wasi` build and runtime, W3 browser `module`, W4
   `component` and WIT, W5 `[npm]` and shims.

## Rationale

No GC or runtime ships to the browser; one WebGPU binding serves native and
browser; LLVM's wasm32 backend and wasi-sdk are mature; async already lowers
through LLVM coroutines; and wasm32 is a triple on an existing backend, so
the MSIL/JVM/native parity rule is unchanged.

## Consequences

W0 changes the ARC object header to an explicit three-field struct on all
targets (LP64 size unchanged at 16 bytes) and replaces hard-coded 8-byte
pointer size tables, which touches the existing native backend and runtime.
