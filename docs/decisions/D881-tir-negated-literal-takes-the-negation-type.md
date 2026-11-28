# D881 - A negated unsuffixed literal takes the type of the negation it is the operand of

**Status:** accepted, implemented in the TIR builder (docs/70 phase 3c, §6.3)

## Decision

1. **`-0.1` under a `Float` expectation builds as a `Float` negation of a `Float` literal.** For `val n: Float = -0.1` the checker records the negation as `Float` and the unsuffixed literal under it as `Double`, because the expected type reaches the prefix node and not its operand. The builder built `IoNeg(Double literal) : Float`, an operator whose result type differs from its operand's, which native refused ("a unary operator whose result type differs from its operand's") and sent to the AST path. The `EPrefix` arm now re-types a numeric literal operand (`TLInt` or `TLFloat`) to the type of the prefix expression when both are numeric primitives and differ, as the binary operators reconcile their operands (`unifyPrimOperands`).
2. A non-literal operand is unchanged, and the literal's value is unchanged: only the node's type is.

## Effect

`float32_self_test.l`'s negated-literal case no longer needs the AST fallback on native; the same shape for an integer literal under another integer expectation is covered by the same rule.
