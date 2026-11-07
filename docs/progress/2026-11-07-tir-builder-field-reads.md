# 2026-11-07 - TIR builder: record field reads (D397)

`Lyric.Tir.Build` builds `recv.field` on a record as `XField` with the field's
declared position, matching the order constructions place fields in. Collection
members, host properties, config fields and payloads stay counted.
`tir_build_self_test.l` is at 76 cases. See D397.
