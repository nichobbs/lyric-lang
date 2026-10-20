# D188 - `foreign record`: C-layout structs at the native FFI boundary

**Status:** accepted, implemented for `--target native` (docs/67 phase G3, #7942); realises docs/67 §4.7

## Decision

1. **Syntax.** `foreign record Name { field: Type ... }`. `foreign` is a contextual
   keyword recognised only as an item head directly before `record`; it stays an
   ordinary identifier everywhere else. `RecordDecl` carries `isForeign`.
2. **Shape (T0178, T0179).** No generics, `where` clause, invariant, method, default
   or `var` field: C writes the memory without running Lyric code, so nothing in
   the record may depend on Lyric-side behaviour. Each field is a `Plain` type,
   `NativePtr[T]`, a constant-length `array[N, T]` of those (not of `NativePtr`),
   or another foreign record. A foreign record is itself `Plain` (D155), so it can
   be a `buffer[T]` element.
3. **Placement (N0101).** Only kernel files may declare one. Kernel files are not
   mode-checked, so the mode checker rejects every foreign record it sees. A
   library's public surface takes ordinary records; the kernel wrapper converts.
4. **Value semantics, in-place writes (T0180).** A foreign record has no identity
   (D157). Assignment and passing copy it. `d.f = v`, `d.arr[i] = v` and `d.f op= v`
   are allowed when the root is a `var` local or an `inout` parameter, and write
   the record in place so `nativeAddrOf(d)` hands C the live storage.
5. **Native lowering.** A foreign record always classifies as a by-value LLVM
   struct, including one with `NativePtr` fields (an ordinary record holding one
   keeps the heap form). Field writes go through the address of the holding place
   (a GEP off `placeAddr`), with no ARC header. A field that has no layout is an
   internal error, never a silent fallback to the heap form. Crossing the C
   boundary uses the by-value record ABI classification already in place (#8009).
6. **Other targets.** A foreign record is a kernel-only native construct; the
   dotnet and JVM kernels never load `_kernel_native/`, so no other backend sees one.

## Consequences

`lyric bindgen` (G3 S3) emits `foreign record` for C structs. The C ABI for
Windows is out of scope until a Windows native target exists (docs/67 §3).
