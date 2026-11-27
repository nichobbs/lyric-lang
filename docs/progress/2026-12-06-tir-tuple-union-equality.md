# Equality of tuples and unions holding arrays on TIR (docs/70 phase 3c, D515)

## What shipped

- `shapeEqCore` expands `ESTuple` and `ESUnion` (typed `TpTuple`/`TpCtor` matches, the union's operands bound once); `wrapLeaves` record leaves and direct `wrapEqSites` use it (D515, amends D506 item 3).
- `tir_build_self_test.l`: a record leaf holding a tuple, a direct tuple, a union, and `!=` build as matches and verify. A native program comparing equal and unequal tuples, unions and records lowers entirely from TIR with the expected output.
