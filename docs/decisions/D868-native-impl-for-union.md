# D868: native lays out an impl whose target is a union

Status: accepted (#9470, part of #7791). Follows D867 (dotnet and the JVM).

## Decision

An impl whose target is a union (`impl Sized for Shape`) was accepted by the checker and failed in the native code generator with an `N0007` invariant violation (no vtable registered): its vtables, impl methods and TIR environment were keyed on record definitions only.

- A union that is the target of an `impl` stays a **heap object**: `fillHeapOnlyRecs` marks it, as it does an opaque type, so it is not classified inline (an inline union is a value with no object to hand an interface box; a by-value record takes the thunk path of #8010, which unions do not need to get).
- `registerImplVtables` builds the vtable of such a union like a record's, over the union pointer (`unionPtrType`), under `<union IR name>|<interface key>`; the impl methods are the same `<Union>.<Interface>.<method>` functions `collectImplMethods` already collects.
- The TIR code generator's environment (`recIrById`) maps a heap union's symbol to its IR name, so `lowerUpcast` finds the vtable for a case value used as the interface, exactly as for a record.

## Not done

A generic union (`impl[T] Holder[T] for Wrap[T]`) is still **N0105**: its vtable would be laid out per instance of the union, as `genericImplVtable` does for a generic record (D864), which needs the union instance's layout (tracked in #7791).

## Verification

`scripts/ci/native-via-tir/unionimpl.l` (a union used through the interface, on the union value, and as an inherited default) builds on both paths with the same output and every function lowered from TIR, and runs clean under AddressSanitizer (`scripts/ci/native-via-tir-e2e.sh`).
