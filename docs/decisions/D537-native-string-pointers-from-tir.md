# D537: the native TIR lowering takes `NativePtr[String]` and the address of a `String` local

Status: accepted (docs/70 phase 4a, part 7; D520 slice 37; extends D534 item 4).

## Decision

`NativePtr[String]` is a raw, uncounted pointer to the `String` reference slot, the form the AST path gives it: the standard library's environment, console and process kernels pass `nativeAddrOf(local)` of a `String` local to a runtime call that stores an owned string through it, and the local's scope releases what the slot then holds. `nativePtrType` accepts a `String` pointee (other reference pointees, records and unions, keep the AST path's form), and `nativeAddrOf` of a `String` local returns the slot address as it does for a scalar.

## Not done

`NativePtr` to a record or union, and `nativeAddrOf` of a local of those types.

## Verification

`scripts/ci/native-via-tir/stringptr.l` (calls `Std.Environment` functions that use the kernel's `NativePtr[String]` out parameters) lowers every function, bundled ones included, from TIR with the AST path's output and runs clean under AddressSanitizer.
