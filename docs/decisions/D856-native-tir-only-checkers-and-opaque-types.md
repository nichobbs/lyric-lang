# D856: the native TIR lowering lays out opaque handle types and lowers bundled-package construction checkers on demand

Status: accepted (docs/70 phase 4a, part 8; D520 slice 45; follows D854).

## Decision

1. **A record with a custom destructor (an opaque type wrapping a raw OS handle, `nativeDtors`) is laid out for the TIR lowering** like any other record. Its layout's destructor is `recDtorName`, which already calls the resource's destructor first and then releases the reference fields (ARC Rule 7), so the gate on `customDtor` was only conservative. Records with callback fields stay on the AST path.
2. **The construction checker `__lyric_checked_T` of a type in a bundled package is lowered from TIR on demand.** The AST path never synthesises it for a bundled package (it is not enforced there at all), so the call TIR makes (D505) had no IR name and every function constructing the type fell back (`DynamicTable`, `Url`). `instantiateTirOnlyFn`, tried beside `instantiateTirFnInst` when a lowering reports a callee without a name, finds the declaration in the monomorphised bundle, lowers it once into the module under `Pkg.__lyric_checked_T` and registers the name; a lowering that falls back unregisters it, so the callers keep the AST path. The invariant of a bundled type is therefore enforced on native when the function constructing it is lowered from TIR, as it is on the other targets.
3. The census trace (`LYRIC_NATIVE_TIR_TRACE=1`) lists each fallback function with its reason, so the next root is named, not counted.

## Not done

The AST path still does not enforce a bundled package's invariants; it is deleted with the default flip (docs/70 §13, phase 4a), not repaired.
