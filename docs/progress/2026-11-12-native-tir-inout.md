# Native backend on TIR: out/inout parameters and field assignment (docs/70 phase 4a, D520)

`Lyric.LlvmTir` lowers `out`/`inout` parameters and arguments (the address of a local or of a
heap record field) and assignment to heap record fields from TIR. `native-via-tir/inout.l`
runs both ways, pins the census at 6 of 6 and is clean under AddressSanitizer.
