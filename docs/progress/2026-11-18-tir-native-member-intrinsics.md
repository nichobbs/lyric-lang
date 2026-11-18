# docs/70 phase 3a: `buffer.withMutPointer` and `NativeWeak.upgrade` build (D421)

The checker records `b.withPointer(f)`, `b.withMutPointer(f)` and `w.upgrade()` as built-in calls by name, so they build as `Intrinsic(IoBuiltin(name))` with the receiver first instead of being counted as unresolved calls (I0002).
