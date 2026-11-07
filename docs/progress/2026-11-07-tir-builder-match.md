# 2026-11-07 - TIR builder: match and patterns (D369)

docs/70 phase 3a, #8613. The checker records pattern types, resolved case and
record symbols, which `PBinding`s are locals, and a sound exhaustiveness proof
per `match`; `Lyric.Tir.Build` builds `XMatch` with `TPat`s. Or-, range,
type-test and constant patterns stay counted as I0002. Tests in
`tir_build_self_test.l`.
