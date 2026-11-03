# `Lyric.Iface` model, canonical codec and `lyric interface dump` (docs/70 phase 5a, D319)

First slice of phase 5a: the `Lyric.Iface` package (header, declaration index,
whole-package re-exports), its canonical binary codec (LEB128, one string
table, sorted canonical order, strict reader), the SHA-256 interface hash, the
text dump and `lyric interface dump <file.lyri>`. Covered by
`iface_self_test.l` (LEB128 edge cases, every declaration kind, order
independence, golden dump, malformed-file rejection). Types, signatures,
embedding and producer validation follow; see D319 for the scope.
