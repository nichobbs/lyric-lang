# D851: the native TIR lowering takes `T.tryFrom` on distinct types

Status: accepted (docs/70 phase 4a, part 7; D520 slice 41; completes the "Not done" of D538).

## Decision

`T.tryFrom(x)` on a distinct type `T` (`IoTryFrom`) lowers as `Result[T, String]`: `Ok(x)` when `x` is in range (always, for a distinct type without a range), else `Err("T.tryFrom: value out of range [lo, hi]")`, the text the AST path and the managed targets produce. `T` is the first type argument of the `Result` instance the node has, so the lowering reads it from the instance table (`TirLowerEnv.instArgs`, filled from the monomorphised bundle's instances); the case values are built by `buildCaseFromVals`, split out of `lowerCase`, and joined through a stack slot. A range subtype or any other shape stays on the AST path.

## Not done

`tryFrom` on a refined range subtype (`TRefined`).

## Verification

`scripts/ci/native-via-tir/ranged.l` gains in-range, below-range, above-range and unranged `tryFrom`; it lowers 12 of 12 functions from TIR with the AST path's output and runs clean under AddressSanitizer.
