# Checker: a pattern binding keeps the enclosing function's type parameters (D566, #8613)

Docs/70 phase 3a: a variable bound by a pattern inside a generic function keeps the function's own
type parameters instead of the lenient error type, and a construction naming them records its field
signature. Census 1079 -> 1080 of 1165 bodies, I0003 0 (see D566). The name cascade (27) is now blocked on
generic calls whose instantiation is unsolved from the arguments. Phase 3a is not complete.
