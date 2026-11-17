# docs/70 phase 3a: an index of any integer type (D496)

`a[i]` with `i` a `Long`, `Byte`, `UInt` or `ULong` keeps the index's own type in TIR (the backend range checks and narrows), instead of being counted as an argument conversion (I0002).
