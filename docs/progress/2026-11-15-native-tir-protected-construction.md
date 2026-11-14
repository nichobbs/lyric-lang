# Native backend on TIR: protected construction (docs/70 phase 4a, D520 slice 27)

Constructing a protected object (user fields, then the mutex buffer in the last field) lowers from
TIR, so a function that builds one no longer falls back. `native-via-tir/protected.l` now lowers
5 of 5 functions, equal to the AST build and clean under AddressSanitizer; the review's nested
`inout` element and `String` compound-in-loop cases were added to `arrays.l` and `elems.l`.
