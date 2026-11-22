# A function-valued binding keeps its built type; a union case's fields convert to the node's type (docs/70 phase 3a, #8613)

**Status:** shipped; typed IR builder.

## Context

`val f = { k: Int range 0 ..= 3 -> k * 2 }`: the checker spells the binding's type from the lambda's own type without its range, and the builder had no conversion from the lambda's type to that spelling. `val r: Result[Long, Int range 0 ..= 3] = Err(ten())`: the case was built at the checker's own instantiation (`Err(Int)`) under a node typed at the settled type, which the verifier rejected (I0003 `construct-field-type`).

## Decision

An annotation the checker spelled from the initializer (no source annotation) that a function value does not convert to leaves the binding at its built type (`buildInit`). A union case built under a node type with type arguments converts each field to the case's declared field type at those arguments (`convertCaseFieldsToNodeType`).

## Results

`range_refinement_self_test.l` 21 of 21.
