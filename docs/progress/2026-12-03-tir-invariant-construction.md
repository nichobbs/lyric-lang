# Type invariants on TIR: constructions are checked (docs/70 phase 3c)

Decision: D505.

## What shipped

- The TIR builder wraps each construction the checker recorded in `invariantCtorSites` in a direct call of the type's `__lyric_checked_T` (`wrapInvariantConstruction` in `lyric-compiler/lyric/tir/build/build_expr.l`), so a function that builds an invariant-carrying type (the native census's `Result[Url, HttpError]` functions) no longer builds a bare construction.
- `Lyric.TypeChecker.functionCallee`: a function as a callee, generic or not; `defaultThunkCallee` is its non-generic form.
- `tir_build_self_test.l`: record, opaque type, and generic record cases, each verified.

## Verification

tir_build, tir_verify, typechecker, contract_elaborator self-tests; see the PR.
