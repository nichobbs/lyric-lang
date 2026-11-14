# Native backend on TIR: arrays and by-value elements (docs/70 phase 4a, D520 slice 26)

Inline `array[N, T]` of by-value elements lowers from TIR (element places, bounds panics with the
AST path's message, nested arrays, arrays in records, `for`, `.length`, `inout` elements). A
by-value record in a `List` or `Map` slot is a counted box copied in and out, `xs[i] += v` and
`m[k] += v` lower, `mapKeys`/`mapValues` are the runtime snapshots, and the call-arity guard added
for #9106 is gone. `native-via-tir/arrays.l` and `elems.l` run both ways and under AddressSanitizer;
arrays of references keep the AST path until the builder carries the checker's copy sites.
