# D572 - Structural equality on declared types builds as an intrinsic (docs/70 phase 3a, #8613)

**Status:** shipped; extends D361 and D568.

## Context

`a == b` and `a != b` on operands that are not primitives (enums, records, unions, `Option`/`Result`,
tuples, collections, distinct and range-subtype values) were reported as `an operator on a declared type`,
the largest remaining I0002 kind. The checker accepts them as the built-in structural relation (language
reference, D164, D172, D206); it records no callee because there is no method to call. Arithmetic and
ordering on refined or distinct values are rejected by the checker (T0030, T0031, T0033), so equality is the
only operator on a declared type that reaches the builder.

## Decision

- `==` and `!=` on non-primitive operands build as `Intrinsic(IoEq)` / `Intrinsic(IoNeq)` over two operands
  of one type. Each backend picks the representation by the operand type (field by field for records,
  case and payload for unions, the underlying value for distinct types).
- When the checker accepted operands of different types (`opt == 5`, a lifted right operand), the right
  operand is converted to the left's type by the usual conversion rules; a bare `None` right operand takes
  the left operand's type. A pair the conversions do not reach is reported as
  `an equality of operands of different types`.
- Every other operator on a declared type is still reported as `an operator on a declared type`.

## Measured

The kind had 183 sites in the compiler area (D571). The `tir_build` self-test passes (129). The wide census was not re-measured for this change, so no before and after count is recorded.
