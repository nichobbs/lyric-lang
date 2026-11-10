# D561 - A declared type passed where an interface is expected is an explicit upcast (docs/70 phase 3a, #8613)

**Status:** shipped; extends D367 and D396.

## Context

`convKindOf` derives the implicit conversions two types alone decide (widening, `Never`, nullable
lift, range check, unrefine). A record passed where an interface it implements is expected was not
among them (it needs the declarations to know the target is an interface), so the builder counted
`an argument conversion` (37 over the stdlib census) and the function never built.

## Decision

`convertValue` falls back to `upcastKind` when `convKindOf` has no answer: the source is a declared
type that is not an interface, and the target is a declared interface, gives `CvUpcast(iface)`. The
checker has already accepted the call, which it does only for a type that implements the interface,
so the builder records the conversion and does not re-derive the implements relation. An
interface-to-interface conversion, and any conversion between other shapes, is still counted.

## Measured

See the progress entry.
