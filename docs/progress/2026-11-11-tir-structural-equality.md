# 2026-11-11 - TIR builder: structural equality on declared types (D572)

docs/70 phase 3a, #8613. The builder lowers `==` and `!=` on enums, records, unions, `Option`, distinct and
range-subtype values to `Intrinsic(IoEq/IoNeq)` over two operands of one type (D572); a bare `None` operand
takes its type from the other side. `tir_build_self_test.l` gains a case covering an enum, record, union,
`Option`, a distinct type and `== None`, each built and verified.

Verified by the `tir_build` self-test (128 pass). The wide census was not re-measured for this change; the
`an operator on a declared type` kind (183 sites in the compiler area, D571) is what it targets.
