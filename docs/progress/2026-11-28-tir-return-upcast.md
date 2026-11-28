# A returned value is upcast to the declared interface (docs/70 phase 3c, D886)

## What shipped

- `returnedAsDeclared` (`tir/build/build_expr.l`): a `return` whose value's type implements the function's declared interface result builds as an upcast (D886). This clears the three `I0003 let-type` diagnostics the wide census reported in `lyric-web` (`staticFiles`, `corsMiddleware`, `corsAnyOriginMiddleware`).
- `pipeReportContractsCensus` prints each diagnostic's function and the symbols its ids name.
- `tir_contracts_self_test.l`: a function with `requires:` returning a record as its interface verifies.
