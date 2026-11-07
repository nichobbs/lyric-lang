# D397 - The builder's record field reads (docs/70 phase 3a, #8613)

**Status:** shipped (`buildFieldRead` in `build_expr.l`); extends D388.

## Context

`recv.name` as a value was an I0002 ("a member access"). A field read is
`XField(recv, FieldRef)`, and `FieldRef` names the declaring record's symbol and
the field's position, which must agree with the position a construction places
it at (D388, the record's declared fields in order).

## Decision

1. `buildFieldRead` builds the receiver and, when its type is a declared type
   (`TNamed(sym, _)`) whose record declares a field `name`, emits
   `XField(recv, FieldRef(owner = sym, name, index))` with `index` the field's
   position among the record's declared fields (`fieldsOfRecord`, now public with
   `FieldEntry`). The node's type is the checker's recorded type, so a generic
   record's field is at the receiver's instantiation.
2. Counted ("a member access that is not a record field"): a collection or string
   member read (`xs.count`), a host property or field, a config field, a tuple or
   union payload and a distinct type's `.value`. Host properties go with the
   extern route (D387), the rest with the tables they need.
3. Reads only. A field as an assignment target is a `TPlace` and comes with
   assignments.
