# wasm32 component shape: hardening after slice 2 (docs/35 W4)

Follow-up to D-progress-1033's review round.

- Two exported functions whose names kebab-case to the same WIT name keep the
  first and leave the second out with a `W0040` (previously the WIT failed
  `wasm-tools` validation).
- The multi-package case D-progress-1033 listed as untested is now covered and
  works: a project with two exporting packages builds, each package gets its own
  WIT interface and shims, and the C primitives declared once per package link
  cleanly (`llvm_wasm32_component_self_test.l`).
- Removed an unused helper and import from `Lyric.ComponentGlue`.
