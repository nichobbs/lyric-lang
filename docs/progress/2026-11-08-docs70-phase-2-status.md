# docs/70 phase 2: status after #8690's per-file import slices

Plugin expansion (including dependency packages), component glue, the weaver's
A0047 lookup and the alias rewriter's synthesised items read each file's imports
(D346, #8908, #8909, #8912); `B0012` is retired (#8915). The cross-file `T0148` and
`T0123` stay and move to phase 4 with the reason in docs/70 §13: the checker's
bare-name tables hold one symbol per name, so per-file candidate selection is what the
TIR resolver does by construction, and the alias rewriter's sibling-rename fallback
and the JVM rename maps (#8895) need the declaration table. A native-only gap found on
the way, `X.newList()` through an alias, is #8913.
