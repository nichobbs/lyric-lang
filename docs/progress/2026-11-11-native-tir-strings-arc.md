# Native backend on TIR: strings and ARC (docs/70 phase 4a, D520)

`Lyric.LlvmTir` lowers `String` from TIR with an explicit ownership model: values are
owned or borrowed, owned temporaries passed as operands are released when their
statement ends, reference locals are released when their scope closes and on every
early exit, and a returned reference is owned by the caller. Literals are static
immortal strings; `+`, comparisons, `String.length`, `toString` of the scalars,
`print` and `println` lower to the runtime. The shared `LyricString` type moved to
`Lyric.LlvmTypes` so both lowerings use one definition.

`native-via-tir-e2e.sh` runs a string program both ways, compares its output with the
specified output, and re-runs the TIR build under AddressSanitizer.
