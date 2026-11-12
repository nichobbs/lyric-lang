# D585 - Nested case patterns are proved exhaustive by a pattern matrix (docs/70 phase 3a, #9025)

**Status:** shipped; extends D369 (`matchExhaustive`).

## Context

The checker records for each `match` whether its arms are *proved* to cover every value (`matchExhaustive`), and the TIR builder copies that into `XMatch.exhaustive`; the native TIR lowering refuses a match whose flag is false. The proof named a case as covered only when its payload patterns were irrefutable, so `case One(Circle(r))` / `case One(Rect(a, b))` / `case Zero`, which covers every `Wrap`, stayed unproved and every such match fell back to the AST path (#9025).

## Decision

- The proof gains a pattern-matrix check (`armsCoverByMatrix`, after Maranget's usefulness test): the unguarded arms are rows, and the check specialises the first column by each case of a union or enum (recursing into the case's payload types), by `true` and `false` for a `Bool`, and by the single constructor of a tuple; a column whose type has no finite constructor set is covered only by a wildcard head. Or-patterns are expanded into one row per alternative.
- It runs in addition to the existing proof, never instead of it, so a match proved before is still proved.
- It fails safe: a pattern it does not read (a literal other than a `Bool`, a range, a record pattern, a type test, a constant) covers nothing, a guarded arm is not a row, a constructor pattern naming more sub-patterns than the case has fields covers nothing, and recursion is bounded, so a `true` answer is never wrong.
- A constructor pattern naming fewer sub-patterns than the case has fields is padded with wildcards, as the backends read it (D578).

## Not done

- The native lowering still handles one level of `TpCtor`; nested case patterns lowered from TIR are on the native backend's list.
- Record patterns do not take part in the matrix.

## Measured

`tir_build` 157, `typechecker` 1145 and `tir_verify` 27 pass; new cases prove the issue's example exhaustive, leave it open when an inner case is missing, prove a `(Bool, union)` tuple only when every pair is covered, and read an or-pattern of cases and a guarded arm soundly. The wide census was not re-measured.
