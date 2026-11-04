# D343 - Every type parameter has a binder, and an empty one is an internal error (docs/70 phase 3a, #8747)

**Status:** shipped. Completes the threading D337 began and removes the
transitional "empty owner matches any binder" rule.

## Context

D337 gave `TyParam(name, owner)` its binder for every function, member, record,
opaque, protected, interface and impl declaration, and let a parameter whose
binder a site did not know keep the empty owner, which matched any binder. That
was the transitional rule that let the change land with no behaviour
difference; it also meant a site that forgot a binder was silently accepted.

## Decision

1. **The remaining sites carry their binder.** Union-case field resolution
   (`unionCaseFieldTypes` takes the union's name), constructor field resolution
   (`ctorFieldTypes`, `collectCtorFields`, `surfaceCtorFieldTypeErrors`, keyed
   by `ctorBinderKey`), the field-default and parameter-default checks
   (`checkDeclaredInit`, `checkParamDefaults`, `noteFieldZeroDefaultOf`, with
   the same keys the signature and body scope use), the definite-assignment pass
   (it takes the function's `Scope` and pushes its parameters with their
   binders), and the interface builder's frames (keyed by the frame's
   `SymbolId`).
2. **The fresh variables of a receiver pattern** (the type arguments of a
   receiver whose method is looked up before they are known) have the reserved
   owner `$receiver`, as a polymorphic builtin's have `$builtin` (D334): they
   are bound by the pattern, not by a declaration.
3. **`TyArray.sizeVar` is a `TyParam`, not a bare name.** It is
   `Option[Type]`, `Some(TyParam(name, owner))` when the length is a value
   generic parameter and `None` otherwise; `hasSizeVar` and `sizeVarName` read
   it. Substituting the parameter keeps the binder of the parameter that
   replaces it.
4. **The empty owner is an I0001 violation.** `gctxPush` (binder unknown) is
   deleted. `gctxPushOwned` and `gctxPushEach` stop the build with `I0001:
   internal compiler error: type parameter(s) T, U pushed into a generic
   context with no binding declaration` when handed an empty owner, and
   `gctxPushEach` also requires its name and owner lists to be parallel. This is
   a panic, not a diagnostic: the site that pushes the names has no diagnostic
   list it can trust (several resolve into a scratch list), and the condition
   is a compiler bug, never a user error.
5. **Equality is strict.** `tyParamOwnersMatch` is `a == b`; an empty owner is
   no longer a wildcard in `typeEquiv`.

## Census (docs/70 section 12.2)

The change cannot reject a program unless a site still builds an empty owner,
which is what the panic reports, so the census is a full run with the rule on:
stage 2 of the bootstrap (it checks the whole compiler and standard library
closure), the checker, parser, resolver, package-merge and Mono self-tests, the
reject corpus, and CI's failed-job logs. All were clean before the PR opened.

## Findings recorded for follow-up

`substituteTyParamsOwned` has no caller that passes owners: all 34 callers go
through `substituteTyParams`, which substitutes by name. The owned path is now
covered directly by a unit case, but moving callers onto it is separate work
(each call site has to know the instantiated declaration's binder keys).
