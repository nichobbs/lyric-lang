# 2026-11-15 - TIR builder: `Self` in an impl member (D476)

docs/70 §6.2, #8613. A member of an `impl` that spells its receiver or result `Self` builds: the conversion maps `Self` to the impl's target type while the member is built (`TyConvCtx.implSelf`). Self-test: `tir_build_self_test.l` (a record impl and a generic `impl[T]`).

Follow-up: the I0002 message for `Self` with no interface or convertible impl target now names both cases; the census script's linked-path and kind-line comments are clarified (review notes on D475, D476).
