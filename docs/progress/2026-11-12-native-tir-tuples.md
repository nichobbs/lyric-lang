# Native backend on TIR: tuples (docs/70 phase 4a, D520)

`Lyric.LlvmTir` lowers tuple construction, destructuring `let` and tuple patterns from TIR.
Tuple layouts are registered on demand by the code generator: a lowering that finds one
missing reports it and is run again (`lowerWithTuples`). `native-via-tir/tuples.l` runs both
ways, pins the census at 6 of 6 and is clean under AddressSanitizer.
