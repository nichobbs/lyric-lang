# 2026-11-15 - TIR builder: open bindings, scrutinees and patterns take the checker's resolved type (D486)

docs/70 phase 3a, #8613. `buildInit`, `buildMatch`, `buildPat` and local reads use `localBindingTypeSites` and the scrutinee's type for what the checker left open (`val o = None; match o { case Some(v) -> v }`, `match (None, 5)`). `tir-builder-shapes-e2e.sh` adds `open_binding_uses`. `expected_type_propagation_self_test.l`: 62 of 68 bodies built; the open tuples fixed through a later pattern store are the remainder.
