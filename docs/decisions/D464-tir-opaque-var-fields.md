# D464 - An opaque type's `var` fields stay assignable in the entry a construction notes (docs/70 phase 3a, #8613)

**Status:** shipped; fixes a regression from D462.

## Context

D462 made the construction of an opaque type build. `noteCtorSym` registers the type's entry from the construction's signature and takes each
field's mutability from `varFieldNames`, which knew record and protected fields but not opaque ones. The wide census then reported I0003
`assign-mutable` for `TestClock.currentEpochMs` (lyric-testing) and `MutableHolder.buf` (`projectable_jvm_self_test.l`): the entry the construction
noted made every field immutable, and the verifier rejected an assignment in another body.

## Decision

`varFieldNames` includes the `var` fields of an opaque type declared in the package (`ownOpaqueFields`). A new `tir_build` case constructs an
opaque type in one body and assigns its `var` field in another.
