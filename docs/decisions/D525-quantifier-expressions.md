# D525 - `forall` and `exists` are built as quantifier nodes (docs/70 phase 3a, #8613)

**Status:** shipped.

## Context

`Lyric.Tir` has `XForall` and `XExists` and the verifier checks them (binders defined for the `where` guard and the body, both `Bool`), but the builder counted every quantifier as "a quantifier": a quantifier may appear only in a `requires:`, `ensures:`, `decreases:` or `invariant:` clause, and a function with one stayed unbuilt (5 unique sites in the self-tests census).

## Decision

`buildQuantifier` opens a scope, declares each binder as an immutable local of its annotated type (`annotatedTy`, so a generic binder resolves in the enclosing generics), builds the `where` guard and the body in it, and closes the scope: `XForall` or `XExists` over the binder locals. The result type is the checker's (`Bool`). A binder named `_` is declared too and is never referenced. No model, verifier or interface change.

## Results

`tir-builder-shapes-e2e.sh` gains `quantifier_clauses` (a `forall` and an `exists` clause; builds with `--verify-ir`, 0 I0003, exits 7).
