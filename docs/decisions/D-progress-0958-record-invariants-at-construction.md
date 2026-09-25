# D-progress-958 — Check record and opaque-type invariants at every construction (#7222)

**Status:** shipped (construction slice; boundary and mutation re-checks remain open under #7222)

## Problem

`invariant:` on a `record`, `exposed record` or `opaque type` was parsed and
dropped. The elaborator only handled functions and protected types, and every
backend's `RMInvariant`/`OMInvariant` arm was empty. So a value violating its
type's invariant was constructed without complaint on MSIL, JVM and native.
That includes `Std.Http.Url` and every library type whose documentation
relied on its invariant.

## Decision

Enforce invariants at construction, the point where every value first comes
into existence, without any backend-specific codegen:

1. **Checker synthesis (before type checking).**
   `Lyric.ContractElaborator.synthesizeInvariantCheckers` runs in
   `pipeExpandAndRewrite`, after `ImplDefaults`. For each such type it
   appends a function to the declaring package:

   ```
   func __lyric_checked_T[G](__lyric_value: in T[G]): T[G]
   ```

   The function asserts each clause, with fields rewritten to
   `__lyric_value.f`, and returns the value. It carries the type's own
   visibility, generics and message
   (`InvariantViolated: Pkg.T invariant <clause>`), and is type-checked and
   exported like any function. Clauses are evaluated in the declaring
   package, so they may call its private helpers. The parameter is not named
   `self`, because that name types as `Self` in a top-level function.
2. **Site recording (type checker).** `inferConstructionExpected` and
   `checkRecordCopy` record each construction of an invariant-bearing type in
   `SymbolTable.invariantCtorSites` (span key → dotted checker path). A site
   is recorded only when the checker function is visible, so a type restored
   from a package built without checkers is constructed unchecked instead of
   failing to compile.
3. **Wrapping (after `.copy` desugaring).** `wrapInvariantConstructions`
   rewrites each recorded `T(...)` into `__lyric_checked_T(T(...))`. The
   wrapper gets a zero-width span so it never shares the construction's span
   key. Wrapping runs after `checkedSourceOut` is captured, so generic bodies
   exported for another package's specialisation stay checker-free. It uses
   a new reusable post-order rewriter, `mapExprsInFile`
   (`contract_elaborator/ast_map.l`).

Supporting changes:

- The type checker now accepts `assert(cond, message)`. The builtin's
  signature gains the optional `String` message that MSIL, JVM, native and
  the book already supported (`builtinOptionalTrailingArgs`).
- `Jvm.Bridge.isMonoSpecializedName` excluded every `__lyric_`-prefixed
  name. A mono copy of a synthesized generic function
  (`__lyric_checked_Box__Int`) therefore got no JVM signature. A `__lyric_`
  name with a further `__` infix after the prefix now counts as a mono copy.
  Test-synth names have no such infix, and B′-mode names keep their own
  collector.

## Not in this slice (tracked in #7222)

- Re-checks after in-place mutation of `var` fields or `inout` parameters,
  and the public-boundary checks of language reference §6.2.
- Constructions inside a generic body that another package specialises.
- Constructions in code synthesized after type checking (derived
  deserializers).
- `@projectable` `tryInto`.
- The native backend's bundled-stdlib path, which elaborates stdlib sources
  without the pipeline.

## Verification

`invariant_self_test.l` has 7 cases on `--target dotnet` and
`--target jvm`:

- a valid construction and a defaulted field;
- the exact violation message;
- each clause checked in turn, including one that calls a `@pure` helper;
- `.copy` in and out of range;
- a generic record;
- an opaque type built by its package's constructor function;
- a construction nested in a match arm.

A two-package project checked constructor, `.copy` and generic
constructions across packages on both targets. Native was checked by hand
(`lyric panic at Ninv:8: InvariantViolated: Ninv.Range invariant lo <= hi`).
