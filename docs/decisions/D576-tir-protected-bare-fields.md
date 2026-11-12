# D576 - A protected member's bare field names are fields of its receiver (docs/70 phase 3a, #8613)

**Status:** shipped; extends D553 and D573.

## Context

D573 builds a protected type's `func`s and entries as declarations with an implicit receiver `self`. Their
bodies name the type's fields without `self.` (`n = n + k`), a spelling the checker types but the builder
reported as "a name that is not a local", and a protected type's type entry had no fields at all.

## Decision

- A non-generic protected type's type entry now lists its fields in declaration order (`PFVar` mutable,
  `PFLet` and `PFImmutable` as declared), through `protectedFieldsOf`; a generic protected type has none yet.
  A construction of the type notes its own entry from the constructor signature, so `varFieldNames` (D569)
  also reads the protected `var` fields: otherwise that entry made every field immutable.
- A bare name that is no local and names a field of the receiver `self` builds as a read of that field
  (`XField`) and, as an assignment target, as a `PlField` place on `self`. `fieldRefOf` falls back to the
  protected type's fields, so `recv.field` on a protected value resolves too.

## Measured

`tir_build_self_test.l` (135): a protected `entry` that assigns a field (`n = n + k`) and a `func` that reads
it both build and verify, and the existing protected construction test now counts its two members. The census
effect is in the progress entry.
