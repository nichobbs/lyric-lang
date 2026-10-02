# wasm32-wasi: kernel pointer handles and the extern ABI audit (docs/35 W2, slice 3)

Third slice of phase W2 (D-progress-1028). A program that reaches the TCP/TLS,
piped-process or HTTP-server kernels now links for `--triple wasm32-wasi` and
fails at runtime with the typed errors those kernels already report.

## The problem

On wasm32 a pointer is `i32` and `Long` is `i64`; wasm-ld rejects a call whose
signature differs from the callee's definition (`-Wl,--fatal-warnings`). The
kernels stored opaque handles as `Long` (a bare `NativePtr[T]` record field is
rejected by the N0100 mode checker) and declared the externs with `Long`
parameters and returns, which x86-64 and AArch64 tolerate.

## The fix

- `tcp_host.l`, `process_piped_host.l` and `http_server.l` declare each handle
  extern with the `NativePtr[Byte]` the C side declares (`<name>Raw`) and keep
  the original `Long`-typed name as a thin wrapper converting with
  `lyric_ptr_to_long` / `lyric_long_to_ptr`. Records and callers are unchanged.
- `rtMalloc` binds `lyric_malloc_raw` (fixed-width size) instead of `malloc`,
  and `rtByteAt` returns `Byte` to match `uint8_t`; the audit found the latter.
- wasi-libc has no `pthread_create`/`pthread_join`. The HTTP server's thread
  externs bind new fixed-width `lyric_thread_create` / `lyric_thread_join`
  wrappers: `lyric_posix.c` forwards to pthreads, and the wasm32 build's
  `lyric_process_unsupported.c` returns `EAGAIN` / `ESRCH`.

## The guard

`scripts/audit-native-extern-abi.sh` compiles the runtime's wasm32 sources to
LLVM IR (`make -C lyric-rt wasm32-wasi-ir`) and `scripts/audit_native_extern_abi.py`
diffs every `_kernel_native` extern's parameter and return classes against the
definition it binds. Run on the pre-slice kernels it reports exactly the 34
mismatches the scan in #8001 found; it runs in the wasm32 CI step so a new
width mismatch fails the build instead of trapping on wasm32.

## Tests

`llvm_wasm32_self_test.l` gains three cases: `spawnPiped` returns `Err`, the TCP
and TLS client dials return `Err`, and `Std.HttpServer.startListener` links and
panics with the runtime's "TCP sockets are unavailable" diagnostic.
