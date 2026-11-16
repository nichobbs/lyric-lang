# 2026-11-16 - TIR builder: the FFI intrinsic calls (D526)

docs/70 phase 3a, #8613. `nativeNullPtr()`, `nativeAddrOf`, `NativeWeak`, `nativeLoadByte`/`nativeStoreByte`, `nativeKeepCallback`/`nativeReleaseCallback` and `externAsObject` build as built-in calls instead of "a call the checker did not resolve". Check: `tir-builder-shapes-e2e.sh` `ffi_intrinsics`.
