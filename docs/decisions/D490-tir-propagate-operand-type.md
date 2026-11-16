# D490 - The operand of `?` that leaves a type argument open takes the type the checker recorded for it (docs/70 phase 3a, #8613)

**Status:** shipped; extends D486.

## Context

`Ok(value = "bb")?`, `Err(error = x)?` and `None?` apply `?` to a construction that leaves a type argument open: the success type of an `Err`, the error type of an `Ok`. The checker records no type for the operand node or for the `?` expression, so the builder counted the body (`propagate_ctor_operand_self_test.l`: 31 of its 58 bodies counted). The checker does record the closed type separately, as a source type keyed by the operand's span (`SymbolTable.hoistOperandTypeSites`, #8181), for the lowering that binds the operand to an annotated local.

## Decision

`buildExpr` for `e?` reads the operand's recorded type (`hoistedOperandTy`, unless the site is marked conflicting), settles the operand to it, and builds it; the type of the `?` itself, when the checker left it untyped, is the first type argument of the operand's type (`Ok(x)?` yields what `x` is, `Err(x)?` and `None?` what the position expects). Where no site is recorded the construction's own payload gives the type: `Ok(x)` and `Some(x)` are typed from `x`, the error type from the enclosing function's recorded type (`openPropagateOperands`). Anything else stays counted.

## Results

`tir-builder-shapes-e2e.sh` gains `propagate_open_operand` (`Ok(..)?` and `Some(..)?` as initializers, built with `--verify-ir`, exit 7). `propagate_ctor_operand_self_test.l` builds 51 of 58 bodies (27 before) and `propagate_ctor_operand_try_self_test.l` 3 of 3 (0 before); 0 I0003. Still open: operands inside a generic function (`okGeneric`, `okTypeParamOperand`, the `errNestedGeneric` family) and `?` used as a statement.
