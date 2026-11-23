# TIR builder: `x.toString()` on a record, union, tuple or collection (D776)

The checker records no callee for `x.toString()`; the builder now builds it as the built-in `toString` for every type D282 renders structurally, not only range subtypes and distinct types. Clears `structural_tostring_self_test` 77 and `structural_tostring_native_self_test` 81.
