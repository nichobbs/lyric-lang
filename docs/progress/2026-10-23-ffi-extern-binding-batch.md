# FFI and extern binding batch (#7889, #7890, #7807, #7682, #7624, #7935)

MSIL auto-FFI reads and calls CLR integers Lyric has no type for correctly:

- A constant field of `SByte` no longer reads as an unsigned byte (`SByte.MinValue` was `128`); the Constant-table decoder sign-extends the one-byte `I1` blob (#7889).
- `UInt32` constants and `UInt32`/`Int16`/`UInt16`/`SByte`/`UInt64` method results and static field reads bind by their real element type, then widen: small types to `Int`, `UInt32` to a zero-extended `Long`. `Int16.Parse`, `UInt32.Parse` and `Convert.ToInt16` used to fail with T0120 because the signature mapper had no representation for these element types (#7890). `ValueTuple.Create` (a generic method on a static class) still fails and keeps the issue open.
- `UInt64` keeps its bit pattern as a `Long` (there is no unsigned 64-bit type), documented in docs/01 section 11.4.

- A generic BCL method taking `T[]` (`Array.Reverse<T>`, `Array.IndexOf<T>`) through `@externTarget` now scores as a candidate, binding `T` from the slice argument; the auto-FFI form still needs generic-method emission, so #7807 stays open (#7807).

Checker and native backend:

- T0140 (a reserved built-in name) now applies to `extern func` declarations, and `isReservedBuiltinFuncName` is derived from `isCodegenBuiltinName` so the two lists cannot drift (#7682).
- A regression test pins that a record argument for an `extern func` `NativePtr[Byte]` parameter is T0043 (#7624, fixed earlier by the extern-call checking work).
- The dead List/Map-to-`NativePtr[Byte]` adaptation in native `externAdaptArg` is removed; the checker rejects those arguments (#7935).

Narrow-integer parameters are not accepted yet (#8482).

Tests: `generic_extern_self_test.l`, `auto_ffi_self_test.l`, `metadata_reader_self_test.l`, `typechecker_self_test.l`.
