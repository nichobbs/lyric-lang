# D596 - Tuple element access is `XTupleField` (docs/70 phase 3a, #8613, #9056)

**Status:** shipped.

## Context

`t.0` is a member access on a tuple. The builder counted it as "a member access that is not a record field", and the native
lowering (#9056) needs the element position, not a name.

## Decision

`XTupleField(recv, index)` is a new expression kind: the element at `index` of a tuple value. `buildFieldRead` builds it when
the receiver's type is a `TTuple` and the member name is a decimal number below the arity. The verifier checks that the
receiver is a tuple (rule `tuple-field`), the index is in range (`tuple-field`) and the node's type is the element's
(`tuple-field-type`). A tuple is immutable, so there is no assignment form. A backend that has no case for the kind reports
it unsupported, as for any new kind; the native lowering reads it with the element position of the tuple layout.
