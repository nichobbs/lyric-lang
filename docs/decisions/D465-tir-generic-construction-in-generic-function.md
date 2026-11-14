# D465 - A generic record constructed at the enclosing function's own type parameter records its signature (docs/70 phase 3a, #8613)

**Status:** shipped.

## Context

`func wrap[U](x: in U): One[U] { One(v = x) }` and `Step(model = m, effects = es)` in `stepAll[M, E]` (lyric-ui) were counted as "a method,
constructor or member call". The checker recorded the callee of the construction but not its signature: `recordCtorSigNode` read a generic
record's fields with `fieldsOfRecordInstantiated`, which ends in `eraseTyParams`, so a field whose type is the enclosing function's own
parameter became `TyError`, `typeIsClosedOver` rejected it and the function returned before `ctorSigByNode` was set. A concrete result
(`One[Int]`) in a generic function, and a generic result in a non-generic one, were unaffected.

## Decision

`recordCtorSigNode` reads a generic record's fields with `fieldsOfRecordSubstituted`: the record's own parameters are replaced by the
construction's type arguments and every other type parameter keeps its binder. `fieldsOfRecordInstantiated` is unchanged for its other callers.
