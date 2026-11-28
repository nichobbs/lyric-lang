# native: an impl of a generic interface for a generic union (D891)

`impl[T] Holder[T] for Wrap[T]` over a generic union builds on `--target native` (it was N0105): the union is a heap object and its vtable is laid out per instance (`genericImplVtable`, `registerGenericImpl`, `fillHeapOnlyRecs` in `llvm_codegen.l`). Covered by `scripts/ci/native-via-tir/genericifaces_union_impl.l` (both paths equal, AddressSanitizer clean). docs/01, book chapter 11 and appendix B updated; closes #9470 and the last native gap of #7791 once merged.
