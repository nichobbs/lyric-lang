# TIR builder: a record's `var` fields are mutable in the symbol entries (D569, #8613)

Docs/70 phase 3a: `build_syms.l` wrote every record field of a `TSymEntry` with `mutable = false`, so the
verifier's `assign-mutable` rule (I0003) flagged any assignment to a `var` field of a `ref record`. The
standard-library tests never assign one, which is why the existing census read zero; the wide census (#8994)
found 377 diagnostics in the compiler, the ecosystem libraries and the self-tests. `varFieldNames` now reads
the `var` fields from the record's declaration. I0003 outside the stdlib tests: compiler 255 -> 27, ecosystem
89 -> 0 (the rest are `call-result-type` and `pattern-arity`). Phase 3a is not complete: I0002/I0003 do not
stop the build yet.
