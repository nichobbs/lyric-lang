# Native backend on TIR: arrays of references (docs/70 phase 4a, D520 slice 30)

Arrays of references lower from TIR using the builder's array-copy and zero-value nodes (D489): the
counted list representation, copied at a store, zero filled with empty strings, bounds-checked
against the array's own length. `native-via-tir/arrayrefs.l` runs both ways and under AddressSanitizer.
