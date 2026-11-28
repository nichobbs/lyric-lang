# D877: the native TIR lowering takes C callbacks and a coroutine's socket twins

Status: accepted (docs/70 phase 4a, part 10; D520 slice 52).

## Decision

A closure passed where a C API wants a callback (`CvCallback`, docs/01 section 11.6) lowers to the address of a `ccc` trampoline the lowering builds into the enclosing function's `extraFns`: it takes the callback's raw parameters, with the userdata slot (`NativeUserdata`, or a trailing `NativePtr[Byte]`) holding the closure, reloads the closure's code pointer from the closure object and calls it with the closure and the other parameters. `CvClosureAsPointer` is the closure pointer as `i8*` and `CvUserdataSlot` the identity. The call-duration borrow needs no retain; a C API that keeps the callback beyond the call takes the pointer `nativeKeepCallback` returns, as before.

A callback whose signature carries a by-value record (the C-ABI form of #8009) stays on the AST path until its trampoline is ported; the census names it ("a callback with a by-value record").

Inside a coroutine, a call of `Std.TcpHost.hostAccept`, `hostRead` or `hostWrite` is an in-place await of its async twin (`hostAcceptAsync`, `hostReadAsync`, `hostWriteAsync`), which parks only the calling task while the socket is not ready (#8494); `coroAsyncTwin` mirrors `nativeAsyncTwin` in `llvm_codegen.l`. The `Result` these return now lowers from TIR, which was the reason the coroutine stayed on the AST path.

`scripts/ci/native-via-tir/callbacks.l` (a `pthread_create` start routine that is a Lyric closure, also passed as the userdata) is built both ways by `native-via-tir-e2e.sh`, must show no fallback, and runs clean under AddressSanitizer.
