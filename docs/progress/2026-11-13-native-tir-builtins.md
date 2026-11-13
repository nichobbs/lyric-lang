# Native backend on TIR: panic, String methods and numeric conversions (docs/70 phase 4a, D520)

The most frequent fallback reasons in the native census (`panic`, `Int.toLong`, `Long.toInt`,
`String.substring`, `codeUnitAt`, `startsWith`, ...) now lower from TIR with the AST path's runtime
calls. `native-via-tir/builtins.l` runs both ways and under AddressSanitizer. `indexOf` and the
`UInt`/`ULong`/`Nat`/`Char`/`Float` conversions stay on the AST path.
