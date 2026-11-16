# 2026-11-16 - TIR builder: `Self` in record and protected type members (D521)

docs/70 phase 3a, #8613. The type `Self` converts to is pushed for every member site (D476 did only `impl` members), so `func inc(self: inout Self)` in a record builds. Self-tests: `tir_build_self_test.l` (a record, a generic record).
