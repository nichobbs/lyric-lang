# D507 - Public-boundary invariant re-checks in the TIR contracts pass

**Status:** accepted, implemented in `Lyric.Tir.Contracts` (docs/70 phase 3c, §7.2; follows D502 and D505)

## Decision

1. **`TFnDecl.isPublic`** (default false) records that the function was declared `pub`; the builder sets it from the declaration's visibility and monomorphisation and contract elaboration carry it.
2. **A public function is an invariant boundary** (docs/08 §7.1), as on the AST (`boundaryEntryChecks`/`boundaryExitChecks`): each `in` or `inout` parameter whose type is a non-generic type of another package that declares `invariant:` clauses is checked on entry, before any `requires:`, by calling the type's `__lyric_checked_T`; each `inout`/`out` parameter of such a type, from this or another package, and the result (a function that is not itself a checker) are checked at every exit, as a synthetic postcondition `{ checker(x); true }` with the message `InvariantViolated: Owner.f parameter p` / `... result`. The clauses on the `TFnDecl` are unchanged.
3. **System checks, not gated by `enabled`**: with contracts off only the source `requires:`/`ensures:` are dropped, the boundary checks and D505's constructions stay, as `#7645` fixed on the AST.
4. **Which checkers**: found in the bundle (`__lyric_checked_T`, one parameter of type `T`) and in `visible`, the other packages of the build. `elaborateBundleWith` takes `visible` and `Pipeline.pipeContractsTir` an optional one; the native bridge passes its own and the standard library's packages to each other. The checkers a package uses get their declaration entries added to the package.

## Not done

Methods and `impl` members (the AST's `selfType` forms), generic invariant types, and a checker only restored from a package interface (no declaration in the bundle) are not boundary-checked here; protected-type invariants (checked at each entry return) are the next slice.
