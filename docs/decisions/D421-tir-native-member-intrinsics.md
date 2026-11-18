# D421 - `buffer.withMutPointer` and `NativeWeak.upgrade` are recorded built-in calls (docs/70 phase 3a, #8613)

**Status:** shipped; extends D364 (built-in callees by name in `builtinByNode`).

## Context

`b.withPointer(f)` and `b.withMutPointer(f)` on a `buffer[T]` (D187) and `w.upgrade()` on a `NativeWeak[T]` (D-N) are typed by the checker through their own early-return paths (`bufferPointerCallType`, `nativeWeakUpgradeType`) and recorded no callee, so every body using one was counted as "a call the checker did not resolve" (I0002) in the native self-tests (`llvm_buffer_self_test`, `llvm_project_self_test` W7.App).

## Decision

Both paths record the member as a built-in callee under the call's node (`recordBuiltinCallee`), as `default()` and the other built-in members are. The builder already builds a recorded built-in member call as `Intrinsic(IoBuiltin(name))` with the receiver as its first argument and the arguments as the checker typed them, so no IR change is needed: a backend lowers them by name, as it does for the FFI intrinsics.

## Results

`scripts/ci/tir-builder-shapes-e2e.sh` builds both for `--target native`: every body builds and the verifier reports nothing (1 of 3 bodies built on the compiler without this change).
