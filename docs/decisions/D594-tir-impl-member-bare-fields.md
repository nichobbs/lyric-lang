# D594 - A bare field name in an impl method is a field of the receiver (docs/70 phase 3a, #8613)

**Status:** shipped; extends D576.

## Context

The census ranked "a name that is not a local" first among the self-tests' uncovered kinds (105), with samples such as
`acc = acc * factor + base` in `impl Scaler for Doubler`: an `impl` method has an implicit receiver and names the
record's field `base` without `self.`. D576 builds the same form for a protected type's members, but `bareSelfField`
looked the name up among protected fields only.

## Decision

`bareSelfField` finds the field with `fieldRefOf`, the lookup a `recv.name` read uses, so a bare name that is neither a
local nor a resolved global and is a field of the receiver `self` builds as a field read or write of `self`. The
receiver's type decides: a record's fields, an opaque type's own fields (D592) and a protected type's fields are all
covered. The checker decides whether the name is a field at all; the builder reads only what it resolved.
