# 2026-11-03 TyVar split into TyParam and TyInfer (docs/70 phase 3a, D329)

- `Type.TyVar(name)` is now `TyParam(name, owner)`, a rigid generic parameter, and `TyInfer(id)` is added for inference variables. About 160 uses across the checker, LSP and self-tests were renamed; `substituteTyVars`, `eraseTyVars`, `typeMentionsTyVar` and `isBareTyVar` became `...TyParams`/`...TyParam`.
- `typeEquiv` is unchanged (both cases are still wildcards), so no accepted program or diagnostic changes. `owner` is `""` everywhere; threading the binder is the start of the rigid-equality step.
- Finding: the checker's unsolved generic arguments are `TyError` holes, not `TyVar`, so the inference-variable work is converting those holes. Recorded in D329 with the T0210 clash: T0210 is the selective-import error, so "cannot infer a type argument" is **T0222** (docs/70 §14 corrected).
- `make stage1-fast` does not report type errors in compiler sources; `make selfhosted-compiler` does. Treat the bundle build as the gate.
