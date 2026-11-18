# D455 - `typeHasUnsolved` matches `TyError` by its payload (docs/70 phase 3a, #8613)

**Status:** shipped.

## Context

The wide census counted `Lyric.TypeChecker::typeHasUnsolved` as "a bare name the checker did not bind" (I0002). Its first arm was `case TyError -> true`, but `TyError` carries a `DiagId`: written without it, the name is a variable pattern that matches every type, so the function returned `true` for any type and its other arms never ran. Its callers (the expected-type bookkeeping that prefers a closed type, and the unsolved-argument checks) therefore always saw an unsolved type.

## Decision

The arm is `case TyError(_) -> true`, as `typeMentionsHole` writes it. The checker's use of the function is unchanged; it now answers for the type it is given.

## Results

The function builds in TIR. Whether the checker should reject a payload case written bare in a pattern is a language question, not decided here.
