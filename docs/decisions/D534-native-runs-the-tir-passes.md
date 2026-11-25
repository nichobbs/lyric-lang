# D534: the native bridge runs `?` lowering and contract elaboration on TIR before monomorphising

Status: accepted (docs/70 phase 4a, part 6; D520 slice 35; consumes D502 and D503).

## Decision

1. **Pass order.** `monoTirInputs` (`llvm_bridge.l`) runs the bundle through `pipePropagateTir` (D503: `?` into a match and an early return), then `pipeContractsTir` (D502: `requires:`/`ensures:` into `assert` calls), then `pipeMonoTir` (D500), as docs/70 §7.2 orders them, so an instance carries both. The bundled standard library's contracts are always elaborated (the AST path's rule, #7748); an own package's follow the manifest's `[contracts]` setting (`enabled = false` leaves bodies alone, as on the AST path).
2. **The lowering accepts elaborated functions.** The clauses stay on the `TFnDecl` for the verifier, so `lowerTirFunction` could no longer tell a function with clauses from one without. `TirUnitInput.contractsElaborated` (set by the bridge) lifts the old blanket "contracts" fallback; TIR the contract pass has not seen still falls back with a reason.
3. **`assert(cond)` and `assert(cond, message)`** lower as the AST path lowers them: a conditional branch, the message evaluated on the failure path only, `lyric_panic_msg` with the package label and line. The panic text is the contract pass's (`PreconditionViolated: Owner.f requires ...`), identical to the AST pass's, which `native-via-tir-e2e.sh` compares for a violated clause.
4. **`nativeAddrOf(local)` and `nativeNullPtr()`** lower from TIR: the address is the local's stack slot, typed as the `NativePtr[T]` the checker gave the call (a local that holds a reference, such as a `String`, stays on the AST path; the TIR `NativePtr[T]` type is scalar-only).

## Not done

- Type invariants, parameter and return range checks, loop `invariant:` lowering, protected-entry clauses and aspect-composed contracts are D502's "not done"; a function that needs one is still lowered from the AST by the existing invariant and aspect gating (`invariantRecs`).
- `nativeAddrOf` of a local that holds a reference type.

## Verification

`scripts/ci/native-via-tir/contracts.l` (`requires:`, `ensures:`, early `return`, `?` on `Result` and `Option`) lowers 6 of 6 functions from TIR with the AST path's output, and a violated precondition panics with the same message on both paths. The native census (20 suites) lowers 1527 of 1744 functions from TIR (it was 1398): the 81 contract and 8 `?` fallbacks are gone.
