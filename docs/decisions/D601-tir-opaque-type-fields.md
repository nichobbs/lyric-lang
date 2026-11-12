# D601 - The fields of an opaque type are readable in its own package (docs/70 phase 3a, #8613)

**Status:** shipped.

## Context

`tir-census.sh --wide` ranked "a member access that is not a record field" first among the ecosystem's uncovered kinds
(101 sites); the first sites (`stmt.text` and `stmt.placeholders` on `lyric-db`'s `opaque type SqlText`) are reads of an
opaque type's own fields. The checker types them (`ownOpaqueFieldType`: the representation is visible inside the declaring
package), but the builder's field lookup read the checker's record fields only, so the type table had no fields for an
opaque type.

## Decision

- `ownOpaqueFields` lists the `OMField` declarations of an opaque type declared in this package, in declaration order; an
  imported opaque type has none.
- `typeEntries` gives such a type its parameters and fields (a generic opaque type's parameters bound under the type's
  name, as a record's are), and `fieldRefOf` finds the field's position among them.
- D600 follow-up: an integer widened to a floating point host parameter scores below the language's own widenings, as the
  CLR's better-conversion rule prefers `M(Long)` to `M(Double)` for an `Int`; `Long` and `ULong` to `Float` and `Long` to
  `Double` can lose precision, as they do in the CLR. A host `float` parameter is not yet widened to: the metadata resolver
  (`iterElemOfSig`) reports it as the host type `System.Single`, not as `Float`, so such a call stays counted.
