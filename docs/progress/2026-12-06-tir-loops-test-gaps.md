# TIR loop-invariant test gaps closed (docs/70 phase 3c, D510)

## What shipped

- `tir_loops_self_test.l`: a labelled `continue outer` from an inner loop sets no break flag on the enclosing `for`, and a `break` in a lambda's own loop leaves the enclosing `for` loop's flag alone (review suggestions on D510).
