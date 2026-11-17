# D530: the zero value of an array of by-value records lowers from TIR on native

Status: accepted (docs/70 phase 4a, part 5; extends D520 slice 31).

## Decision

`XZeroValue` (`var a: array[N, T]` with no initializer) lowers from TIR when the element is a by-value record, not only a scalar. The zero is `zeroinitializer` of the inline array when the all-zero bit pattern is the checker's zero (`zeroExprFor`, `typechecker_arrays.l`):

- the record is by value (no `var` field) and no field declares a default, because a default makes the zero a different value than all-zero bits (`n: Int = 5`);
- every field is a scalar (enum fields are their `i32` ordinal, whose first case is 0), an inline array of such elements, or another record with the same property.

The code generator owns the declaration, so `TirRecLayout.zeroBits` carries the first condition; `structZeroOk` in `llvm_tir.l` checks the second over the registered layouts. A record with a field default, a record with a reference field (it has no zero: T0156 in the checker), and an array held as a list stay on the AST path, which builds the checker's zero expression; the census reports them as fallbacks.

## Why not carry the zero expression in TIR

`XZeroValue(ty)` names the type only. Defaults are part of the record declaration, not of TIR, and rebuilding the zero from them in the backend would be a second `zeroExprFor`. Where the answer is the all-zero pattern the lowering needs only a flag; where it is not, the AST path remains the single implementation. If the default case matters, the builder can emit the constructor call as a TIR expression (docs/70 §8), which is a builder change tracked with phase 3c.

## Verification

`scripts/ci/native-via-tir/arrays.l` (`zeroRecords`, `zeroNested`) runs the same program through the AST and TIR paths, compares output, checks there is no TIR fallback, and runs the TIR build under AddressSanitizer.
