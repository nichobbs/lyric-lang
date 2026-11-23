# Every field of a foreign record is writable in place in the typed IR (docs/70 phase 3a, #8613)

**Status:** shipped; the TIR symbol table.

## Context

`lyric-gpu/src/gpu.l` writes the fields of a bindgen `foreign record` in place (`entry.buffer = longToPtr(buffer.raw)` on a `var entry = WGPUBindGroupEntry(...)`). The language reference (section 3.4) exempts a `foreign record` from the immutable-field rule (V0015): its in-place writes are judged by T0180, since the record is a C-layout struct whose fields are filled by assignment. The typed IR's symbol table recorded only declared `var` fields as mutable, so the verifier (D323) rejected every such write: I0003 `assign-mutable`, "assignment to the immutable field buffer", on the native build of `lyric-gpu` (#9282, `native-backend-self-tests`).

## Decision

`varFieldNames` (the builder's list of a record's writable fields) counts every field of a `foreign record` as writable, as the language does. No other record changes.

## Consequences

The native build of `lyric-gpu` passes the verifier. Test: `tir_build_self_test.l` (a write to a foreign record field, built and verified).
