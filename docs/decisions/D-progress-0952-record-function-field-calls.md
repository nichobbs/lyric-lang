# D-progress-952 — Calling the function held in a record field

**Status:** shipped

## Problem

`r.f(args)`, where `f` is a function-typed field of `r`'s record, type-checks
but was lowered as a method call on the record by both backends: MSIL
emitted a run-time "unsupported method" throw and the JVM an `invokevirtual
R.f(...)` against a method that does not exist (`NoSuchMethodError`). The
only working spelling was to read the field into a local first. Records of
functions are the natural shape for a program description
(`lyric-ui`'s `Program { update, view, uiEffect }`), so the gap blocked it.

## Decision

- **MSIL.** At the method-dispatch point of `lowerMethodCallMsil`, a receiver
  whose record (plain or in-bundle generic) has a function-typed field `f`
  and no method `f` reads the field and invokes it
  (`recordFuncFieldCallMsil`, through `invokeLoadedFuncValueMsil`, so a
  `Unit`-returning field uses its `Action` shape). The field's registered
  result type unboxes the result.
- **JVM.** When every method, extension and FFI resolution has missed and
  the receiver's record has a field `f`, the field is read and invoked
  through the lambda interface (`lowerLambdaInvokeTail`) instead of the
  `invokevirtual` guess; the type checker has already established that the
  field holds a function.
- **Mono.** `lookupRecordMethodRetTE` falls back to a function-typed field of
  that name, substituting the record's type parameters, so a generic call
  on the result (`describeOne(ue)` after `case Some(ue)` on
  `p.uiEffect(e)`) specialises. `inferMethodReturnTE` also matches a
  package-qualified receiver type by its simple name.

A method of the same name still wins, as in the type checker.

## Verification

`record_function_field_self_test.l` (both targets, wired into CI) covers a
plain record's function field, its result in arithmetic, a `Unit`-returning
field, a generic record's field with its result matched, and a method next
to a field function.
