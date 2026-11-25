# Native TIR lowering: NativePtr[String] (docs/70 phase 4a)

Decision: D537. Slice 37 of phase 4a, part 7.

## What shipped

- `nativePtrType` accepts a `String` pointee, so the kernels' `NativePtr[String]` parameters and `nativeAddrOf` of a `String` local lower from TIR (`lyric-compiler/lyric/llvm_tir.l`).
- `scripts/ci/native-via-tir/stringptr.l` and its block in `scripts/ci/native-via-tir-e2e.sh`.
