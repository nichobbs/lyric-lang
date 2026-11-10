# TIR: union case constructions with an unsolved result argument (D560, #8613)

The checker records a union case's construction signature from its closed field types even when the
result type still has an unsolved argument, so `Err(error = 1)` passed to a generic call builds.
Census: bodies built 1016 -> 1028 of 1165, I0003 0.
