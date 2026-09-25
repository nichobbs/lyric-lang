# D-progress-949 — JVM: annotated locals of a generic-record type keep the record class

**Status:** shipped

## Problem

On the JVM, every generic type other than a bare `List`/`Map` erases to
`java/lang/Object` (`typeExprToJvm`). #6691 recovered the real class for a
generic-record *parameter*, but a *local* annotated with a generic-record
type (`val b: Box[Int] = makeBox(21)`, and the `var`/`let` forms) still took
the erased slot type. Every field read on it then went down the
erased-receiver path: J007 at compile time, or, for a field named `count`,
the `__lyricCount` helper casting the record to `Object[]` at run time. The
shape is common wherever a generic function returns a generic record, and
it is exactly what an imported generic's specialised call produces, so
cross-package generic code could not run on the JVM.

## Decision

`localAnnotatedJvmType` (every annotated `val`/`var`/`let`) recovers the
record's class through `recordParamClassOf`, the same `ctx.ctors` registry
lookup parameters and constructor calls use; the store `checkcast`s to it.
`recordParamClassOf` now also resolves a package-qualified head
(`Other.Box[Int]`, the form alias rewriting produces for `import Other as O`
+ `O.Box[Int]`) through the registry's dotted package-qualified key, never
the bare-name fallback.

## Verification

`generic_param_field_read_jvm_self_test.l` gains annotated `val`, `var` and
`let` cases and a generic record with a field named `count`; all three fail
before the change. The cross-package repro (qualified calls, return-only type
parameters, record copy in imported generic bodies) passes on the JVM as
well as on .NET.
