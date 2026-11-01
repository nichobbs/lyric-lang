# D307 — Release contract policy applies to impl, record and protected-type methods (#8680)

**Status:** accepted, implemented

Completes the member half of D297, which applied the release contract policy
to free functions only.

## Decision

In a `release` build (and when neither `--release-contracts` nor
`@runtime_checked(release_contracts = full)` keeps every check), the policy of
book chapter 17 section 17.4 covers every function-like member:

1. **Record methods and protected-type entries and funcs.** `ensures:` is not
   checked. These members have no visibility of their own, so they take their
   type's: `requires:` is checked only when the type is `pub` (a caller outside
   the package can reach no other member).
2. **`impl` methods.** The method's own `ensures:` is not
   checked; its own `requires:` is kept, as the method is reached through its
   interface. The clauses it inherits from its
   interface (#7223) keep their `requires:` (an interface method is callable
   from outside the package, so its precondition is a public boundary) and
   lose their `ensures:`.
3. **Protected types.** The type's `invariant:` clauses are system-level and
   are always checked at every entry and func exit; only a user `ensures:` is
   elided.
4. Clauses stay on the declaration, so contract metadata and the verifier see
   what was written; `@proof_required` packages and the standard library are
   still never elided (the pipeline only marks files that qualify).

Mechanism: the same view-then-restore step `elaborateItem` uses for free
functions, threaded through `elaborateRecordDecl`, `elaborateImplDecl` /
`elaborateFunctionWith` and `elaborateProtectedMember`. No backend change; all
three targets behave the same.

## Consequences

`scripts/ci/release-contracts-e2e.sh` builds a program per member kind (record
method, `impl` method, interface-inherited clause, protected entry and func,
protected invariant) debug and release on dotnet, jvm and native.
