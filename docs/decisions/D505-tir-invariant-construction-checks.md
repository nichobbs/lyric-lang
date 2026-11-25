# D505 - Type invariants on TIR: a construction is its checker called on the built value

**Status:** accepted, implemented in the TIR builder (docs/70 phase 3c, §7.2)

## Decision

1. **A construction of a record or opaque type that declares `invariant:` clauses is `__lyric_checked_T(T(...))` in TIR**, as `Lyric.ContractElaborator.wrapInvariantConstructions` rewrites it on the AST (#7222). The checker is an ordinary function the declaring package already holds (`synthesizeInvariantCheckers` runs before the check), so the wrap is an `XCall(Direct(checker, typeArgs), [TArgIn(construct)])` at the construction's type; its assertion lowers like any other body and carries the `InvariantViolated: Pkg.T invariant ...` message the checker was given.
2. **The builder does it, in `buildExpr`**, from the table the checker already fills (`SymbolTable.invariantCtorSites`, keyed by the call's span, covering constructor calls and `.copy`). No checker change: the checker function's `SymbolId` and signature come from `Lyric.TypeChecker.functionCallee` (the generic-capable form `defaultThunkCallee` now delegates to), and the type arguments of a generic record are those of the constructed type. A checker the table does not hold, or whose type parameters differ from the type's, is an I0002 uncovered kind, never a silent unchecked construction.
3. **Verified** by `Lyric.Tir.Verify` (the callee is a declared function with the recorded signature) and by `tir_build_self_test.l` cases for a record, an opaque type, `.copy`, and a generic record.

## Not done

Tracked as the next slices of phase 3c: the public-boundary and `inout` re-checks (`boundaryEntryChecks`/`boundaryExitChecks`, which belong in the D502 contracts pass) and protected-type invariants checked at each entry return.
