# 2026-11-15 - TIR builder: the operand of `?` that leaves a type argument open (D490)

docs/70 phase 3a, #8613. The builder types `Ok(x)?`, `Err(x)?`, `Some(x)?` and `None?` from the checker's `hoistOperandTypeSites` (with a payload-based fallback), settling the operand and the `?` node. `tir-builder-shapes-e2e.sh` adds `propagate_open_operand`; `propagate_ctor_operand_self_test.l` 27 -> 51 of 58 bodies, its `try` sibling 0 -> 3 of 3.
