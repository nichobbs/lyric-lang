# D329 - `TyVar` splits into `TyParam` and `TyInfer`; the "cannot infer" code is T0222 (docs/70 phase 3a, #8613)

**Amended by D331:** the code in item 4 is **T0224**, not T0222; D312 had already
taken T0222 (bare enum-case ambiguity).

**Status:** step 1 shipped (the types and the rename, no behaviour change).
Steps 2 to 5 of the §5 type rules (rigid parameters, the unsolved-variable
diagnostic, `TyError` with a diagnostic, builtin signatures, the I0001 gate)
follow, each in the two-step form of docs/70 §12.2.

## Context

docs/70 §5.1 splits the checker's `TyVar(name)` into a rigid generic parameter
and an inference variable. Reading the checker shows the two roles are not
mixed in `TyVar` the way the design assumed: every `TyVar` the checker builds
is a named generic parameter (resolver, signatures, `substituteTyParams`), and
the "unsolved" state of a generic argument is `TyError` used as a hole
(`typeIsHole`, `inferOneGenericArg` returning `TyError`). So the work is the
other way round: rename `TyVar` to the rigid case, and turn the holes into
inference variables.

## Decision

1. `Type` gains `TyParam(name: String, owner: String)` in place of
   `TyVar(name)`, and `TyInfer(id: Int)`. `owner` is the qualified name of the
   declaration that binds the parameter; it is `""` where the checker does not
   yet thread the binder (every site today). Threading it is the first part of
   the next step, because rigid equality needs it: two nested generic
   declarations may each bind a `T`.
2. `typeEquiv` still treats both as wildcards in this step, so the rename is
   behaviour-preserving. The helpers are renamed with the case
   (`substituteTyParams`, `eraseTyParams`, `typeMentionsTyParam`,
   `isBareTyParam`).
3. `TyInfer` has no construction site yet; the next step creates one per
   generic call and binding where `TyError` stands for "not yet solved".
4. **Code allocation.** docs/70 §14 reserved **T0210** for "cannot infer a
   type argument", but T0210 shipped in phase 1 as the selective-import check
   (docs/01, "package P declares no 'X'"). The unsolved-variable diagnostic
   is **T0222** instead; the docs/70 table and §5.2 are corrected here. T0211
   to T0213 keep the meanings docs/70 gave them.

## Consequences

The rigid-parameter, T0222, `TyError` and I0001 steps each reject code the
compiler accepts today and land with a census (docs/70 §12.2). Nothing in
docs/01 changes in this step: no accepted program and no diagnostic differs.
