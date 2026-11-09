# 2026-11-09 - TIR builder: val patterns, for loops, uninitialized vars (D544)

docs/70 phase 3a, #8613. `val` of a pattern, `var x: T` without an initializer and
`for` loops (with range iterators) build as `TsLet`, `TsVar` and `TsFor`; the checker's
`val`/`for` pattern binder records pattern types and binding nodes. Removes the
cascade that inflated `a name that is not a local`. `tir_build_self_test.l` has 97
cases. Census figures are in D544.
