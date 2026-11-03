# D337 - A type parameter carries the declaration that binds it (docs/70 phase 3a, #8747)

**Status:** step one shipped. Binders are threaded through every function,
method, record, opaque, protected, interface and impl declaration; a parameter
whose binder a site does not know keeps the empty owner and matches any binder.
Step two (strict owners) is tracked in #8747.

## Context

D329 split `TyVar` into `TyParam(name, owner)` and `TyInfer(id)` and D331 made
`TyParam` rigid, but `owner` was `""` at every construction site, so two
declarations that each bind a `T` compared equal, and `substituteTyParams`
replaced an outer `T` that an earlier instantiation had put into a type when it
applied the inner declaration's arguments. `Lyric.Tir` already keys a parameter
by `TParam(owner, index)`, so the TIR builder needs the real binder.

## Decision

1. **`GenericContext` records the binder of each parameter** (`owners`, parallel
   to `params`). `gctxPushOwned(ctx, names, owner)` pushes with a binder,
   `gctxPushScope(ctx, sc)` pushes a body scope's parameters with theirs, and
   `gctxOwnerOf` reads the innermost binder. `gctxPush` keeps meaning "binder
   unknown".
2. **Binder keys.** A free function is keyed by its name, a member by
   `Type.member`, a record, union, opaque, protected type, interface or alias by
   its name, and an impl block (which has no name) by `impl@<file>:<offset>`.
   The key is computed by one helper per declaration kind, so the signature, the
   body scope and the declaration checks agree.
3. **Where the owner is stored.** `ResolvedSignature.genericOwners` (parallel to
   `generics`, a member's own parameters), `Scope.genericOwners` (the body's full
   list, owner type first), and the resolver builds `TyParam(name, owner)` from
   the context for both type and value generic parameters.
4. **Substitution is by `(name, owner)`.** `substituteTyParamsOwned` replaces a
   parameter only when its binder matches, so an inner `T` is never replaced by
   an outer instantiation. `substituteTyParams` (names only) remains for sites
   that do not know the binders.
5. **Equality.** `typeEquiv` compares `(name, owner)`; an empty owner matches any
   binder (`tyParamOwnersMatch`). This is the transitional rule that lets the
   change land with no behaviour difference for code the census cannot reach.
6. **Sites still on the empty owner**: union-case and constructor field
   resolution (`unionCaseFieldTypes`, `ctorFieldTypes`, `collectCtorFields`),
   the field-default checks, and the definite-assignment pass. They resolve with
   `gctxPush` and names only; tracked in #8747 together with making the empty
   owner an I0001 gate violation.

## Verification

Typechecker self-test cases for distinct binders, a generic call chain, and a
generic record method with its own parameter; the full verification set
(docs/70 §12.2 census) on the PR.
