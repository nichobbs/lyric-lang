# TIR: built-in member calls take their parameter types from the checker (D556, #8613)

The checker records the function type of each built-in member call's callee
(`builtinFnTyByNode`) and the builder converts the call's arguments to it, so `s.substring(0, 1)`,
`s.replace(a, b)` and the integer bitwise methods build with explicit conversions where the argument
needs one. Census: bodies built 992 -> 1006 of 1165, I0003 0, the kind `a built-in call with an
argument the builder cannot check` 27 -> 0.
