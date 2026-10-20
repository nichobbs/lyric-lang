# D193 - Callback members of a `foreign record`

**Status:** accepted, implemented for `--target native` (docs/67 phase G5 prerequisite, #7944); extends D188 and D189

## Decision

1. **The field.** A `foreign record` field may be a C callback: a function type with a
   `NativeUserdata` parameter, whose other parameters and result are C-passable (T0179
   otherwise). `NativeUserdata` is also allowed as a plain `void*` field. This is how
   `webgpu.h` (`WGPURequestAdapterCallbackInfo`) and SDL3 carry callbacks.
2. **Layout.** The field is a pointer-sized slot; the record stays an LLVM struct and crosses
   the C boundary by value or pointer under the existing ABI lowering.
3. **Construction.** A construction takes a Lyric closure of the callback type minus its first
   `NativeUserdata` parameter (the one the trampoline unwraps, D189) for the callback field,
   and stores the address of that callback's C trampoline. A closure given for a `NativePtr[Byte]`
   or `NativeUserdata` field is stored as its own pointer, the userdata C passes back. The checker
   reuses the `extern func` argument rule (`argSatisfiesExternParam`) for these fields only.
4. **Lifetime.** Nothing retains the closure: the program keeps it alive until C has finished
   calling it, which for a one-shot request is the wrapper's own scope.
5. **bindgen.** A function-pointer struct member becomes such a field; a callback with several
   `void*` parameters needs a `userdata <callback> <index>` line (webgpu callbacks carry two).

## Not in this slice

Assigning a closure to a callback field of an existing record (`info.callback = f`); construct a
new record instead. A closure literal written inline needs an annotated function type, so the
examples bind it to a `val` first.
