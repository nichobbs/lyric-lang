# D554 - A function finds its symbol by its own declaration span (docs/70 phase 3a, #8613)

**Status:** shipped; extends D540. The protected-entry decision is D553 (renumbered from a second D552).

## Context

The TIR census counted `a function with no symbol` (37) and `a generic function with no symbol` (3).
The sites were plain top-level functions (`hx`, `oc`, `grantAllows`, `newConcQueue`) and
`@externTarget` functions with a placeholder body. A minimal case showed the cause: a function with
a `///` doc comment or an annotation had no symbol. `symTableFuncSymOf` matched the symbol's
`declSpan`, which is the item's span (it starts at the doc comment or annotation), against the
`FunctionDecl.span` (which starts at `func`), so the two never agreed.

## Decision

`symTableFuncSymOf` compares the `FunctionDecl.span` of the declaration the symbol carries with the
function's own span. Both are the same node, so they agree however the item is documented or
annotated.

## Measured

`scripts/ci/tir-census.sh` over the 98 programs: bodies built 969 -> 992 of 1165, I0003 0,
`a function with no symbol` and `a generic function with no symbol` 0. Bodies that built for the
first time reach further, so `a built-in call with an argument the builder cannot check` rises
13 -> 27 (the next slice's kind). Methods and impl members are still not walked by the census.
