# D-progress-966 — Qualified calls in restored generic bodies; restored function fields (#7250)

**Status:** shipped

## Problem

A restored library's generic function carries its body as source (#6363),
recorded after alias rewriting. A call to a sibling package written
`Session.start(m)` is therefore stored as `Ui.Session.start(m)`. When the
consumer re-parses that text, a dotted call parses as a member chain
(`EMember(EMember(EPath Ui, Session), start)`), and only the alias rewriter
turns such a chain into a package call. It never ran over restored bodies,
so the specialised copy reached MSIL codegen as a method call on the value
`Ui.Session` and failed with T0115. `lyric-ui`'s `Ui.Host.instance` hit this
for every consumer of the prebuilt `Ui.dll`. In-bundle builds and the JVM,
which calls restored generics erased rather than specialising them, were
unaffected.

## Decision

When the MSIL bridge collects a restored package's generic functions for
specialisation, `Lyric.Pipeline.pipeRestoredItemsWithImports` re-runs the
alias rewriter over the package's items with its recorded `imports` (contract
metadata, D-progress-946) in scope. Qualified calls resolve exactly as they
did in the package's own build. The synthesized source itself, and its
bodyless surface check (D-progress-953), are unchanged.

A restored record's function-typed field now registers its parameter and
result types when the record's fields are registered, as an in-bundle
record's already did (#5511), so `r.f(args)` on a restored record invokes the
field on MSIL (D-progress-952 covered in-bundle records only; the call threw
"unsupported method" at run time).

## Verification

`cross_package_generics_self_test.l` builds a two-package producer DLL whose
generic calls `Session.start(m)` in a sibling package inside a closure, then
builds and runs a consumer against the restored DLL; the consumer calls the
returned record's function field.
