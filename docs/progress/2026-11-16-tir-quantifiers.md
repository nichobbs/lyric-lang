# 2026-11-16 - TIR builder: quantifiers (D525)

docs/70 phase 3a, #8613. `forall` and `exists` in contract clauses build as `XForall` / `XExists` over their binder locals. Check: `tir-builder-shapes-e2e.sh` `quantifier_clauses`.
