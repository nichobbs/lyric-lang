# D875: the native TIR lowering takes `default()` of any representation

Status: accepted (docs/70 phase 4a, part 9; D520 slice 52).

## Decision

`default()` is the zero value of the representation, as on the AST path: `0`, `false` and `0.0` for scalars, a null pointer for a `String`, a heap record, a list or a union object (the placeholder a later `out` argument or assignment replaces, releasing nothing; the runtime reads a null string as empty), and `zeroinitializer` for a by-value record or inline aggregate. D859 kept every non-scalar on the AST path. `keptast.l` prints `default()` of a `String`, a by-value record and a list that is assigned before use, and the e2e requires that none falls back.
