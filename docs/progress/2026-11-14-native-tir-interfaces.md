# Native backend on TIR: interfaces (docs/70 phase 4a, D520)

Heap records used as non-generic interfaces (the box with the retained object and the record's vtable)
and calls through the box lower from TIR with the code generator's box and vtable layout. Methods with
`Self`, by-reference parameters or async, generic interfaces and by-value records stay on the AST
path. `native-via-tir/ifaces.l` runs both ways and under AddressSanitizer. Impl methods are still
lowered by the AST path: the TIR lookup matches top-level functions only.
