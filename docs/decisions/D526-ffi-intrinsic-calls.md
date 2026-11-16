# D526 - The FFI intrinsic calls are built-in calls in the TIR (docs/70 phase 3a, #8613)

**Status:** shipped.

## Context

`nativeNullPtr()`, `nativeAddrOf(x)`, `NativeWeak(x)`, `nativeLoadByte`/`nativeStoreByte`, `nativeKeepCallback`/`nativeReleaseCallback` and `externAsObject(x)` are typed by name in the checker (`nativeIntrinsicCallType`, `externUpcastCallType`) and lowered by name in every backend; no callee, signature or built-in table records them. The builder counted each use as "a call the checker did not resolve", which kept every `@unsafe_ffi` function and the native kernels that call them (`pointerRoundTrip`, `nullCString`, ...) unbuilt (the largest single group in `extern_cbinding_self_test.l`).

## Decision

`buildCall` takes a call whose callee is one of those names (a single bare name that is no local) as a built-in call (`Intrinsic(IoBuiltin(name))`), typed as the checker typed the call. They count as generic built-ins: no argument is converted, and the "argument the builder cannot check" rule does not apply, since their parameters are not widening targets. No model, verifier or interface change.

## Results

`tir-builder-shapes-e2e.sh` gains `ffi_intrinsics` (built and verified, not run: the dotnet backend does not lower `NativePtr`).
