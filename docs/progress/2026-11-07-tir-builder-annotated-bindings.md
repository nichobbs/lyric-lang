# 2026-11-07 - TIR builder: annotated bindings and derived conversions (D396)

`Lyric.Tir.Build` builds annotated `val`/`let`/`var` bindings, converting the
initializer to the annotation, and one `convKindOf` now decides every implicit
conversion from the two types (widening, `Never`, nullable lift, range check,
unrefine). Distinct wraps, interface upcasts, host boxing and slice/list stay
counted. `tir_build_self_test.l` is at 73 cases. See D396.
