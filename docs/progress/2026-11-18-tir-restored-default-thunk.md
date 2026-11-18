# docs/70 phase 3a: a restored package's default argument builds (D457)

A call that leaves out a defaulted argument of a restored package's callable calls the package's compiled default thunk, so it builds in TIR instead of being counted as "a default argument declared in another package" (I0002).
