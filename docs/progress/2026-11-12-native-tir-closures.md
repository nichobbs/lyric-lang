# Native backend on TIR: closures (docs/70 phase 4a, D520)

`Lyric.LlvmTir` lowers function types, lambdas with by-value captures and calls through
function values from TIR, using the AST path's closure object layout. Closure types are
registered on demand by the code generator (as tuples are); lambda bodies and environments
come back with the lowered function. `native-via-tir/closures.l` runs both ways, pins the
census at 6 of 6 and is clean under AddressSanitizer.
