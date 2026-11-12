# Native backend on TIR: text and common patterns (docs/70 phase 4a, D520)

`Lyric.LlvmTir` lowers string interpolation, `match` on a `String` against literals, `Double`
literal patterns and string indexing from TIR. A census over a probe program ranked the
remaining gaps (lists and `Option` behind monomorphisation, tuples, enums, closures, nested
case patterns); `native-via-tir/text.l` pins this slice both ways and under AddressSanitizer.
