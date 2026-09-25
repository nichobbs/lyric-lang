# D-progress-955 — Enforce contracts on record-body, impl and interface methods (#7223)

**Status:** shipped

## Problem

`Lyric.ContractElaborator.elaborateItem` handled only top-level `IFunc`
items and protected types. `requires:` / `ensures:` written on a method
inside a `record { }` body or an `impl` block were parsed, kept in the AST,
and never lowered to runtime checks. Contracts declared on interface method
signatures had no effect on any implementation. There was no diagnostic, so
authors had no way to know their method contracts were decorative. Across
the stdlib and ecosystem libraries about 90 such clauses (for example the
`StorageBucket`, `JobScheduler`, `CacheStore` and `SearchClient`
interfaces) were never checked.

## Decision

1. **Record-body and impl methods** are elaborated exactly like top-level
   functions.
2. **Interface clauses are inherited additively.** Each `impl` method is
   checked against its interface method's `requires:` / `ensures:` **and**
   its own, conjoined, with the interface's clauses first. This matches the
   aspect composition rule (D047): an implementation can add obligations but
   cannot remove the interface's. We did not adopt Liskov-style
   "implementation may weaken the precondition" (disjunction): it cannot be
   expressed as a single runtime check without evaluating both sides, and
   the aspect precedent already establishes conjunction as the language's
   composition rule.
3. **Parameter binding is positional.** Interface clauses refer to the
   interface method's parameter names. They are renamed to the implementing
   method's parameter names by position, shadow-aware: lambda parameters,
   quantifier binders, match-arm pattern bindings and block-local bindings
   inside a clause stop the rename for their scope. A signature whose arity
   differs from the implementation's contributes nothing; the type checker
   reports the mismatch.
4. **Resolution.** Interfaces are looked up by bare name, first among the
   file's own declarations, then among the cross-package interface
   declarations the pipeline already collects for the monomorphizer
   (`elaborateFileWithInterfaces`). Implementations of external (FFI)
   interfaces have no Lyric clauses to inherit.
5. **Verbatim default copies are not re-inherited.** `Lyric.ImplDefaults`
   copies an un-overridden interface default method into the impl, clauses
   included, before elaboration. An interface clause that the method already
   carries (same source span, same text) is skipped, so each clause is
   asserted exactly once (#7291).
6. **Source clauses are preserved.** The elaborated function's `contracts`
   list is restored to the author's own clauses, so contract metadata and
   the verifier see only what was written on that declaration.

## Consequence for library interfaces

An interface precondition now binds every implementation, so it must only
describe programmer obligations. `lyric-storage`'s `StorageBucket` declared
`requires: isSafeKey(key)` on every data-plane method. Storage keys usually
come from untrusted input, and `LocalBucket` already returned
`Err(INVALID_KEY)` for them. With the clause enforced, that recoverable
error became a crash, and five existing tests failed. The interface
therefore drops the key and prefix clauses, keeping the programmer-supplied
bounds (`contentType`, `maxKeys`, `expiresInSeconds`), and documents that
every implementation validates keys itself. `LocalBucket.list` gains the
prefix check it was missing. The type-level fix, an opaque `StorageKey`, is
tracked in #7242.

## Verification

`method_contracts_self_test.l` (9 cases, `--target dotnet` and
`--target jvm`) covers:

- satisfied and violated preconditions on a record-body method;
- an inherited precondition under a renamed parameter;
- the same precondition through an interface-typed value;
- an inherited postcondition;
- an impl's own precondition combined with an inherited one;
- an inherited default method's precondition, evaluated exactly once per call.

The existing ecosystem suites that now exercise live interface contracts
(cache, db, feature-flags, i18n, jobs, mq, search, storage, testing) pass.
