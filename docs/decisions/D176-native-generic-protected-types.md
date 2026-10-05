# D176 - Native: generic protected types

**Status:** accepted, implemented (`--target native`)

Resolves #7864; lifts the D-N-017 and D147 deferrals. Reverses D147 item 4 (the build-time N0008).

## Decision

A generic protected type lowers on native by reusing the generic-record and generic-function machinery:

1. **Layout.** The declaration registers as a generic record over its fields and is flagged in `protectedRecNames` under its own key. Each instantiation (`Cell[Int]`) gets the user fields with the type arguments substituted, the trailing `__mutex: i8*` field, and the mutex-tearing-down destructor (`synthProtectedDtor`). It is always a heap object, never a by-value record.
2. **Construction.** `lowerGenericRecordConstruct` infers the type arguments as for a generic record, then allocates and initialises the lock buffer (`emitMutexBuf`) and builds the object with `lowerProtectedConstructVals`.
3. **Members.** `collectProtectedMethods` emits, per entry and func, a generic `<Type>.<m>.__inner` carrying the desugared body and a generic `<Type>.<m>` wrapper whose body is `__lyric_protected_lock()`, the call to the inner function, `__lyric_protected_unlock()`. The wrappers are ordinary generic functions, instantiated per use and found through the instance's generic key like a generic record's methods. The two new intrinsics share `lowerProtectedMutexOp` with the `when:` barrier intrinsics, so barriers on a generic protected type work unchanged.
4. **Diagnostics.** `N0008` and its pre-pass are removed.

5. **Two native gaps found by the shared test.** A field default built from a type parameter (`var item: Option[T] = None`) is now lowered after the type arguments are bound, against the field's type, for every generic record (it failed with "cannot infer the type arguments of generic union case 'None'"). The property spellings `opt.isNone` / `opt.isSome` lower by comparing the Option's discriminant (they were unsupported on native).

## Not covered

Generic members (T0135 on every target), async funcs and value generic parameters on a protected type (#8149) are unchanged.

## Tests

`llvm_self_test_n34.l` (ASan, Int and String instantiations) and `generic_protected_self_test.l` on `--target native`.
