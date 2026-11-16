# D478 - Compound assignment to a host property and writes to a public host field (docs/70 phase 3a, #8613)

**Status:** shipped; completes the two cases D598 left counted.

## Context

D598 built `recv.p = v` on a host value as a call of the property's setter. It counted two forms: a compound assignment (`recv.n += 1`, a read-modify-write that must evaluate the receiver once) and a write to a public field (no setter method exists).

## Decision

- A write to a member with no `set_<name>` method but a public instance field of that name is an `Extern` call with `kind = HMFieldSet`, `params` the receiver then the field's type, and the value converted to it as an argument is (`hostArgConv`). A read-only property (a getter alone) is still counted.
- `recv.p op= v` on a primitive member is a block `{ val r = recv; r.p = r.p op v }` of type `Unit`: the receiver is bound once to a fresh local, the read is the property's getter (or field read) of that local, the operator is the built-in arithmetic intrinsic with the value converted to the member's type (a `String` member appends the value's `toString`), and the write is the setter or field write above. A member the checker did not type, or one that is not primitive, is counted with the site in the message.
- The setter or field resolution moved into `hostWriteCall`, shared by the plain and compound forms.

## Not covered

An indexer write and a static property or field write are still counted.
