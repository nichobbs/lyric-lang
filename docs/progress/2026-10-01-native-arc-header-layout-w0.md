# Native backend: target-width-independent heap layout (docs/35 W0)

First slice of the wasm32 plan (D-progress-1028, `docs/35` phase W0). It makes the
native backend's heap layout independent of the host's 64-bit pointer width.
Output on the existing x86-64/AArch64 targets is unchanged in size and
behaviour; every native self-test suite passes before and after.

## ARC header is an explicit three-field struct

The C `LyricObjectHeader` is `{ rc, weak, dtor }`, but codegen modelled it as
`{ i32, i8* }` and relied on `weak` sitting in LP64 alignment padding. On a
32-bit target there is no padding, so `dtor` would have been at offset 4 in
the IR and offset 8 in C. Codegen now models `{ i32 rc, i32 weak, i8* dtor }`
everywhere (`addArcHeader`): records, tuples, unions, closures, interface
boxes, strings (including string literals), lists, maps and tasks. Every GEP
index that was a bare literal (`2 + field`, closure capture base, union
discriminant and payload slots, interface box slots, the dtor store) is now a
named constant (`arcHeaderSlots`, `closureFnSlot`, `closureCaptureBase`,
`unionDiscSlot`, `unionPayloadSlot`, `arcDtorSlot`, `ifaceBox*Slot`). The
`_Static_assert`s in `lyric_rt.h` now check the layout (rc at 0, weak at 4,
dtor at 8) instead of "two words", and the header compiles cleanly for
`wasm32-unknown-unknown`, where the struct is 12 bytes.

## Allocation sizes come from LLVM

`sizeOfN`/`alignOfN`/`structSize`/`recAllocSize`/`unionAllocSize` hard-coded
8-byte pointers and fed every `lyric_alloc` call. `emitHeapAlloc` now takes
the size from a new `NSizeOf` instruction (`ptrtoint (T* getelementptr (T, T*
null, i32 1) to i64)`), so it follows the target's datalayout by construction
and `recAllocSize`/`unionAllocSize` are gone. The remaining table
(`structSize`) only sizes union payload word arrays at type-definition time;
it now takes the target pointer width from the triple (`ptrBytesForTriple`,
`Ctx.ptrBytes`).

## Coroutine frame size needed no change

`llvm.coro.size.i64` was flagged by the wasm32 audit, but the intrinsic's
integer width is only the result type and `lyric_alloc` takes `i64` on every
target, so the call is correct as is.

## `Long`-as-pointer externs audited

Of the 107 `_kernel_native` externs that mention `Long` or `NativePtr`, the
ones that must work on wasm32 (console, encoding, environment, file, math,
string, time, uuid) are already width-stable: pointers are `NativePtr[Byte]`
and runtime helpers use `int64_t`. The `Long`-as-pointer-handle idiom is
confined to the TCP/TLS, HTTP server and piped-process kernels, which are
unavailable on WASI and get wasm twins in W2. The one remaining exposure was
`libc.l`, whose `write`/`read`/`strlen`/`malloc` take `size_t`/`ssize_t`
(32-bit on wasm32) and whose `open` is variadic; those externs now call
fixed-width `lyric_write_fd`/`lyric_read_fd`/`lyric_cstr_len`/
`lyric_malloc_raw`/`lyric_open_fd` wrappers in `lyric_posix.c`.

## Verification

- `llvm_ir`, `llvm_codegen`, `llvm_heap` (ASan), `llvm_ffi`, `llvm_collections`,
  `llvm_stdlib`, `llvm_self_test_n3`/`n34`/`async`/`defer`/`self_iface`/
  `impl_direct`, `llvm_opaque`, `llvm_enum_case_resolve` and `llvm_inout` all pass.
- `lyric-rt` C tests pass under clang and gcc (new cases cover the fixed-width
  wrappers).
- New `llvm_heap_self_test.l` cases lower a program using every header-bearing
  heap shape for `wasm32-unknown-unknown`, assert the three-field header and
  `NSizeOf` allocation, and compile the IR with clang's WebAssembly backend.
- `llvm_ir_self_test.l` covers `NSizeOf` rendering.
