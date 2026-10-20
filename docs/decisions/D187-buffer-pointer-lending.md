# D187 - Lending a buffer's address: `withPointer` and `withMutPointer`

**Status:** accepted, implemented for `--target native` (docs/67 phase G2, #7941)

## Decision

1. **Surface.** On a `buffer[T]` held in a variable or field path,
   `b.withPointer({ p: NativePtr[T] -> ... })` calls the closure with a pointer
   to the packed elements and returns the closure's result. `withMutPointer`
   does the same after making the storage unique (the copy-on-write step of
   D186), so it needs a writable place (**T0157**) and the closure may write
   through the pointer without disturbing another binding.
2. **Native only.** The other targets have no address to lend (**T0175**).
3. **The closure writes its parameter's type** (**T0176**). That annotation is
   what places the call under the FFI boundary: a `NativePtr` type expression
   is **N0100** outside `@unsafe_ffi` functions and `_kernel_native/` packages,
   and the mode checker now applies that rule to a lambda parameter as well as a
   signature or a local.
4. **The pointer does not escape.** Inside the closure the parameter may appear
   only as a call argument or a member receiver; returning, binding, assigning
   or capturing it is **N0102**. A nested closure that mentions the pointer anywhere
   holds it past the call, so it is `N0102` too. Deeper aliasing is out of scope,
   as for `nativeAddrOf`.
5. **Result type.** The checker records the closure's result type for each call
   (T0177 when it cannot be written out), and the shared lowering binds the
   closure literal to an annotated `val` before the call, so the backend has the
   function type it lowers a closure against.
6. **Lowering.** The codegen takes the address of the first element, stores it in
   a fresh local, and calls the closure with that local as its argument. No
   runtime function is involved.

## Not in this decision

Zero-copy mapped GPU buffers need the same closure form on a mapped view and
come with `lyric-gpu` (docs/67 §4.4).
