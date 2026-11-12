# D587 - A binary operator on non-primitive operands is one intrinsic over both operands (docs/70 phase 3a, #8613)

**Status:** shipped; extends D572 (equality on declared types).

## Context

D572 built `==` and `!=` on non-primitive operands as one intrinsic, lowered by each backend by the operands' type. Every other operator on a non-primitive left operand was counted as `an operator on a declared type`: the ordering operators a type derives or a type parameter is bounded by (`a > b` with `T: Compare`, a distinct type deriving `Compare`), and the arithmetic of a distinct, range or record type that derives `Add`, `Sub` and the rest (language reference, derives). The wide census held 27 such sites in the self-test area.

## Decision

- The same intrinsic form serves them all: `buildDeclaredBinary` emits `IoLt`, `IoLte`, `IoGt`, `IoGte`, `IoAdd`, `IoSub`, `IoMul`, `IoDiv`, `IoMod` and the rest over both operands, with the result typed as the checker typed the expression (`Bool` for a comparison, the operand type for derived arithmetic).
- The right operand is converted to the left's type when the checker accepted a difference, as for equality; a difference no conversion derives is counted as `an operator on operands of different types`.
- What the intrinsic means for a type is the backend's to lower, by the operands' type, as it is for equality: a distinct value acts on its underlying value, a range subtype's derived arithmetic is range-checked as a construction is (`T.from(a.value op b.value)`), an operand of type parameter type is lowered after specialisation. The verifier does not constrain intrinsic operand types, so none of this is checked on the TIR itself.

## Measured

`tir_build` 160 and `tir_verify` 27 pass; a new case builds and verifies `a > b` with `T: Compare`, derived `+` and `<` on a distinct type, and derived `+` and `<=` on a range-subtype distinct type. The wide census was not re-measured for this change.
