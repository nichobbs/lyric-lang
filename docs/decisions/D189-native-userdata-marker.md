# D189 - `NativeUserdata`: the userdata slot of a C callback at any position

**Status:** accepted, implemented for `--target native` (docs/67 phase G3, #7942); realises docs/67 §4.8

## Decision

1. **Marker.** A native-only built-in type `NativeUserdata` (a `void*`, lowered to
   `i8*`, registered like `NativeWeak[T]`) is written as a parameter type of an
   `extern func` callback type: `(NativeUserdata, NativePtr[Event]) -> Bool`.
   docs/67 §4.8 proposed an `@userdata` annotation; function-type parameters carry
   no annotations, and a type survives into the resolved signature that the
   checker works from, so the marker is a type.
2. **Closure type.** The closure a callback parameter takes is the callback type
   without its `NativeUserdata` parameter. The first `NativeUserdata` is the slot.
   The older form (no marker, trailing `NativePtr[Byte]`) is unchanged.
3. **Trampolines.** Both the plain and the by-value C-ABI trampoline take the
   closure pointer from the marked slot and call the closure with the remaining
   parameters in C order.
4. **Passing the closure.** A closure in a `NativeUserdata` argument position
   lowers to the closure pointer, as for `NativePtr[Byte]`. `NativeUserdata` is under
   `N0100` like `NativePtr`.

## Consequences

SDL3 callbacks (`userdata` first) and webgpu callback-info structs can be bound
without a hand-written C shim. `lyric bindgen` (G3 S3) emits `NativeUserdata` for a
`void*` parameter named `userdata`/`user_data` in a callback typedef.
