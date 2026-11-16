# 2026-11-16 - TIR: compound assignment to a host property, writes to a public host field (D478)

docs/70 phase 3a, #8613. `recv.n += 1` on a host value builds as a block that binds the receiver once and writes `r.n op v`; a write to a public host field builds as an `HMFieldSet` call. Self-tests: `tir_build_self_test.l`; a real program (`host_compound_and_field_writes`) in `scripts/ci/tir-builder-shapes-e2e.sh`.
