# D-progress-970 — A record `.copy` argument is built at its field's type

**Status:** shipped

## Problem

`Lyric.Mono` desugars `r.copy(f = v, ...)` into a block that binds the
receiver and each argument to a temporary, in source order, and then calls
the constructor (D-progress-948). The argument temporaries were unannotated.
A bare `None` or `newList()` argument therefore had no expected type, and on
MSIL it was built as `Option<object>` / `List<object>`. A later `match` on
the field tested `isinst Option_None<string>` and failed with "match not
exhaustive". The JVM, which erases the type argument, was unaffected.
`m.copy(saveError = None)` in `examples/ui-customers` hit this.

## Decision

The type checker records each field's type, at the receiver's instantiation,
on the copy site (`RecordCopySite.fieldTypes`, written by `typeExprForRef`, so
`None` where a type has no spelling at the use site). The desugar annotates
each argument temporary with its field's type when one is recorded, so the
argument is built at that type. Copy sites that `Lyric.Mono` synthesises for
specialised bodies record the declared field types of a non-generic record
and none for a generic record, whose field types name its type parameters.

The receiver and arguments are still evaluated once, left to right.

## Verification

`record_copy_self_test.l` ("copy with a bare None or empty list argument keeps
the field's type") copies with `note = None` and `tags = newList()`, then
matches the field and adds to the list, on MSIL and the JVM. It failed on
MSIL before the change. `examples/ui-customers` uses `.copy` for every model
update.
