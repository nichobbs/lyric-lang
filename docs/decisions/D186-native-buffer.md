# D186 - `buffer[T]` on native: packed ARC storage and copy on write

**Status:** accepted, implemented for `--target native` (docs/67 phase G2, #7941); completes D185's native half

## Decision

1. **Representation.** A buffer is a reference-counted block
   `{ i32 rc, i32 weak, i8* dtor, i64 len, i64 elem_size, [0 x T] }`
   (`LyricBuffer` in `lyric-rt`, `__buffer<T>` in the codegen). The elements are
   `Plain`, so they are stored packed and by value after a 32-byte header,
   16-byte aligned, with no per-element ownership and no destructor. The element
   type is read back from the struct's own last field, so the code generator
   keeps no side table of buffer types.
2. **Copy on write.** Unlike the managed targets (D185), a store of a buffer
   copies nothing: `__lyric_array_copy[buffer[T]]` is the identity and the
   binding that holds the value retains it. A write `b[i] = v` / `b[i] op= v`
   to a place loads the block's count; one is written in place, anything else
   first takes a private copy (`lyric_buffer_unique`, an owned reference) and
   stores it back to the place, so a buffer other bindings still hold is left
   alone. The fast path is one load and a branch, and allocates nothing.
3. **Operations.** `b.length`/`.count` reads the length field; `b[i]` addresses
   the element by a GEP into the packed array and loads it (the shared lowering
   has already checked the index against the length); `for` iterates the block
   the loop started with, since the loop's own binding retains it.
4. **`Std.Buffer` bridge.** `__lyric_buffer_from_list` and `__lyric_buffer_as_list`
   are copy loops between a list and a buffer, so the same `Std.Buffer` source
   runs on every target. A native-specific constructor that skips the list is a
   follow-up optimisation of `filled`.
5. **Element types.** A buffer element whose native type is a reference is
   **N0021**; a `Plain` type never is.

## Verification

`llvm_buffer_self_test.l` builds whole programs with AddressSanitizer and
LeakSanitizer: packed layout in the emitted IR, no allocation for 1000 writes to
an unshared buffer, one copy for the first write to a shared one, a sole owner
writing in place again once the copy is released, and balanced counts across
passing, returning, record fields and `inout`. `buffer_self_test.l` and
`buffer_spawn_self_test.l` run on native too. The `lyric-rt` unit tests cover the
kernels.

## Not in this decision

`withPointer`/`withMutPointer`, the verifier's array model and the lint rule
(docs/67 G2), and the JVM spawn argument copy (#8391).
