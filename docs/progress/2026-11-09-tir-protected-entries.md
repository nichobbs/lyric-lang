# TIR: protected-type construction and entry calls (D552, #8613)

`Total()` builds as an `XConstruct` and `t.add(n)` as a receiver-first direct call to an entry
symbol (`TSkEntry`); `TFnDecl` carries an optional `barrier` the verifier checks as `Bool`.
The checker records a non-generic protected type's construction signature. Covered by a
`tir_build` self-test case; census: bodies built 967 -> 969 of 1165, I0003 0, receiver-less method calls 39 -> 30.
