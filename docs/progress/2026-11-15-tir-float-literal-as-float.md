# 2026-11-15 - TIR builder: a float literal where a Float is expected (D491)

docs/70 phase 3a, #8613. `convertValue` retypes a `Double` float literal to `Float` where a `Float` is expected instead of counting a conversion the model does not have. `tir-builder-shapes-e2e.sh` adds `float_literal_argument`; the `Double` to `Float` argument conversions in `lyric-conformance` and `lyric-testing` are gone.
