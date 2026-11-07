# 2026-11-07 - TIR builder: record and union-case constructions (D388)

docs/70 phase 3a, #8613. The checker records the fields of each non-generic
construction as a signature (`ctorSigByNode`); `Lyric.Tir.Build` places the
arguments with the shared `buildCallArgs` and builds `XConstruct` with the
fields in declaration order. Generic, opaque, exposed-record and defaulted-field
constructions stay counted I0002. Tests in `tir_build_self_test.l`.
