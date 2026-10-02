# `--triple wasm32-wasi` links and runs Lyric programs under wasmtime (docs/35 W2, slice 2)

Second slice of phase W2 (D-progress-1028): the compiler half. A Lyric program
now compiles with `lyric build --target native --triple wasm32-wasi` to a core
`.wasm` that runs under a WASI runtime. Slice 1 (#7995) built the runtime.

## Link recipe

`llvm_bridge.l` picks the toolchain by triple. A `wasm32` triple links with the
wasi-sdk's clang (`$WASI_SDK_PATH`, `N0009` when unset) and `--sysroot`, against
the per-triple runtime archive (`$LYRIC_RT_WASM32_PATH`, the installed
`lib/lyric_rt-wasm32-wasi.a`, or `lyric-rt/build/wasm32-wasi/lyric_rt.a`);
`$LYRIC_RT_PATH` is the host archive's override and never applies. `-lpthread`
and `-ldl` are not passed. `wasm32-wasi` is normalised to clang's
`wasm32-unknown-wasi` so clang does not warn about overriding the module triple.

## Entry point

wasi-libc starts a program through `__main_argc_argv`; a plain `main(argc,
argv)` is an undefined weak symbol there that traps on entry. Codegen names the
synthesised C entry per triple (`entryNameForTriple`).

## ABI widths now enforced

wasm-ld compiles a call whose signature differs from the callee's definition
into a trap and only warns; x86-64 tolerates the same mismatch. The wasm32 link
now passes `-Wl,--fatal-warnings`, which turned two latent mismatches into
failures, both fixed on every target:

- the codegen's `lyric_console_write_line` declaration passed an `i64` fd where
  the runtime takes `int32_t` (every `println`);
- `rtByteAt` in `encoding_host.l` and `http_server.l` passed an `Int` index
  where `lyric_string_byte_at` takes `int64_t`.

A scan of every `_kernel_native` extern against the runtime's definitions found
the remaining mismatches are all pointer handles declared as `Long` (the
TCP/TLS, piped-process and HTTP-server kernels, plus the HTTP server's use of
`lyric_mutex_*` and `lyric_sem_*`). A program that reaches them does not link on
wasm32 yet; replacing the idiom with explicit `lyric_long_to_ptr` conversions is
slice 3. Programs that merely do not use them are unaffected.

## Tests

`llvm_wasm32_self_test.l` (8 cases, wired into the wasm32 CI step through
`scripts/ci/wasm32-wasi-rt-tests.sh`) compiles Lyric programs through the real
bridge and runs them under wasmtime: exit code and stdout through the wasi-libc
entry point, every header-bearing heap shape, binary32 `Float` arithmetic and
rendering, `Std.Environment.args`, a `Std.File` round trip through a preopened
directory (visible on the host), the clock/sleep/uuid seams, `Std.Process`
reporting `Err` rather than trapping, and a panic's message and nonzero exit.
Every native suite passes unchanged (`llvm_ir`, `codegen`, `heap`, `ffi`,
`collections`, `stdlib`, `n3`, `n34`, `async`, `defer`, `opaque`,
`enum_case_resolve`, `inout`, `self_iface`, `impl_direct`, `tls`, `http_client`,
`http_server`).
