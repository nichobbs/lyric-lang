# `Lyric.Tir`: the typed IR data model, docs/70 phase 3a step 1 (#8612)

D319.

- **`Lyric.Tir`** (new, `lyric-compiler/lyric/tir/`): `tir_ty.l` has `NodeId`,
  `LocalId`, `Ty` (no error and no inference case), `ArrayLen`, `HostTypeRef`,
  `tyEq` (no wildcard; a refinement is not its underlying type) and
  `renderTy`. `tir_ir.l` has `TExpr`/`TExprKind`, `Callee`, `TArg` modes,
  `TPlace`, `ConvKind`, `IndexKind`, typed patterns and statements, captures,
  `HostMemberRef`, and the declaration records (`TFnDecl`, `TSig`,
  `TSymEntry`, `TPackage`).
- Tests: `tir_self_test.l`.
- Phase 5a (`Lyric.Iface`) reuses `Ty`.
- Next in 3a: `Lyric.Tir.Verify` (I0003), `NodeId`s on the parser's nodes, then
  the §5 type rules, each in the two-step form.
