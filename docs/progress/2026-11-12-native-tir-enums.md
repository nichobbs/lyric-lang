# Native backend on TIR: enums (docs/70 phase 4a, D520)

`Lyric.LlvmTir` lowers enum values and case patterns from TIR as `i32` ordinals, with the
enum and case tables built once per unit by the code generator from its `enumDefs`.
`native-via-tir/enums.l` runs both ways and pins the census.
