# D-progress-950 — Member reads on an imported generic's call result

**Status:** shipped

## Problem

A field read directly on the result of a call to an imported generic that
returns a generic record (`tally(xs).count`, `pairOf(1).n`) failed on both
targets, and on MSIL could silently read the wrong type:

- **MSIL.** `addPackageTokens` resolves each function's declared return type
  as it registers the function. The consumer's specialised copy of an
  imported generic lives in the consumer's package, and when that package is
  tokenised before the package declaring the returned generic record, the
  record's head is not yet in `genericTypeArity`, so the return type erased
  to `object`. `lyric test` bundles a test package FIRST (#2885), so every
  test that did this was affected. A `.n` read then failed with T0121; a
  `.count` read treated the record as a collection; and an unannotated local
  bound to the result (`val p = pairOf("x"); p.n`) resolved `n` by bare name
  against an unrelated same-named field in the consumer (`LocalPair.n`),
  emitting a cast to the wrong class.
- **JVM.** A specialised copy's signature kept `recordRetClass = None`
  (#6399 narrows only same-file generic records), so the call result stayed
  `Object`: J007 for `.n`, and `__lyricCount` casting the record to
  `Object[]` for `.count`.

## Decision

- **MSIL.** `Msil.Codegen.preRegisterPackageTypeNames` registers every
  package's type names and generic record/union arities, in bundle order,
  before any package is tokenised. It mirrors exactly the registrations
  `addPackageTokens` makes for the same items (records, exposed records,
  unions, interfaces, projectable views, distinct types), so every
  first-wins name resolution is unchanged; `addPackageTokens` re-registers
  them idempotently.
- **JVM.** `JvmFuncSig.recordRetHead` carries the return type's generic head
  for a mono-specialised copy, and `narrowStaticCallResult` resolves it at
  the call site through the complete `ctx.ctors` registry (bare head:
  `ctorClassFor`; qualified head: the dotted package-qualified key) and
  `checkcast`s the result, as #6399 does for same-file records.

## Verification

`emitter_project_self_test.l` builds a two-package project with the
consumer listed first and reads `.count`, `.n` and an unannotated local's
field on imported generic call results, on MSIL and on the JVM; both cases
fail before the change.
