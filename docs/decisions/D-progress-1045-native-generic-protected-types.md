# D-progress-1045 — Generic protected types on the native backend (#7864)

**Status:** shipped. Lifts the generic-protected-type deferral recorded in
D-N-017 and the native rejection (`N0008`) in D147 item 4.

## Decision

`--target native` monomorphises a generic protected type per instantiation,
the way it already monomorphises a generic record:

- **Layout.** The declaration's user fields register as a synthetic generic
  record (`registerGenericProtected`), flagged in `ctx.protectedRecNames`.
  `instantiateGenericRecordOpt` appends the trailing `__mutex: i8*` field for a
  flagged type, never makes it a by-value record, and attaches
  `synthProtectedDtor` (release the ref-typed fields, destroy and free the
  mutex buffer) instead of the plain record destructor.
- **Members.** `collectProtectedMethods` now emits the `<Type>.<m>.__inner`
  bodies as generic functions over the type's parameters, with `Self` replaced
  by `Type[T, ...]`. Each `entry`/`func` also registers a body-less generic
  wrapper under the member's own name, where a generic record's method is
  found. Instantiating that wrapper lowers the `.__inner` body under the type
  arguments and hand-builds the lock/unlock `NFunc` with the same
  `synthProtectedWrapper` the non-generic path uses.
- **Construction.** `lowerGenericRecordConstruct` allocates the mutex buffer
  (`emitMutexBuffer`, shared with `lowerProtectedConstructArgs`) and builds the
  object with `lowerProtectedConstructVals`.

The `N0008` diagnostic and its `Lyric.LlvmBridge` pre-pass are removed.

## Unchanged

Protected `when:` barriers and invariant re-checking stay unimplemented on
native, for generic and non-generic types alike (D-N-017). An `impl` for a
generic protected type is still T0136; a method-generic member is T0135.

## Verification

`generic_protected_self_test.l` runs under `--target native` in the native
backend CI lane, and `llvm_self_test_n34.l` runs a generic protected type under
AddressSanitizer across 30 constructions of two instantiations.
