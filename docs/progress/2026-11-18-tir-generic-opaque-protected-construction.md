# docs/70 phase 3a: a generic opaque or protected type's construction builds (D454)

The checker records a construction signature for a generic opaque or protected type, with its fields at the result type's arguments, so the construction builds in TIR instead of being counted as "a method, constructor or member call" (I0002).
