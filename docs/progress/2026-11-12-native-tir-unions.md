# Native backend on TIR: unions (docs/70 phase 4a, D520)

`Lyric.LlvmTir` builds union cases and matches them from TIR, in the inline tagged-value
form and the heap form with reference payloads. The code generator hands over each
union's layout and each case's place in it; the lowering tests the discriminant, tests
scalar sub-patterns on the payload, and binds payload fields as borrows of the scrutinee.

`native-via-tir-e2e.sh` builds `native-via-tir/unions.l` both ways, checks the specified
output, and recompiles the TIR build's IR under AddressSanitizer.
