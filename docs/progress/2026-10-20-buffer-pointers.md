# `withPointer` and `withMutPointer` on buffers (docs/67 G2, #7941, D187)

`b.withPointer({ p: NativePtr[T] -> ... })` and `b.withMutPointer(...)` lend a
buffer's packed elements to a closure on `--target native` and return its result.

- Checker: `bufferPointerCallType` types the call (T0175 off native, T0176 for a
  closure that does not write its parameter's type, T0177 for an unspellable
  result type, T0174 for an unstable receiver, T0157 for `withMutPointer` on a
  non-writable place) and records the result type per call.
- Lowering: the shared pass binds the closure literal to an annotated `val`;
  the native codegen takes the address of the first element and calls the
  closure with it, after the copy-on-write step for `withMutPointer`.
- Mode checker: a lambda parameter written `NativePtr[T]` is under `N0100`, and
  inside the closure the pointer may only be a call argument or a member
  receiver (`N0102`).
- Tests: two native ASan cases in `llvm_buffer_self_test.l` (`memset` through
  `withMutPointer` leaving a shared snapshot alone; `nativeStoreByte` /
  `nativeLoadByte` round trip and an empty buffer), mode-checker and checker
  cases.
- From the `#8392` review: a threading note on `lyric_buffer_unique` and a C test
  for the size-overflow panic.

Open under #7941: the verifier's array model, the `lyric lint` rule, the lazy
managed form (#8389), a native `filled` that skips the list, and the JVM spawn
argument copy (#8391).
