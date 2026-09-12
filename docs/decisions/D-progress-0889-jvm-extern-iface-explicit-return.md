# D-progress-889 — JVM codegen: an explicit `return` inside an extern-interface impl method now narrows a `slice[Elem]` return the same way the implicit tail-position path does (#5931 review follow-up, #7004)

**Status:** shipped

**Context.** Automated review of the D-progress-885/886/887/888 fix chain
noted that `lowerInstanceMethodBody`'s tail-position return coercion was
switched to the ctx-aware `coerceArgToCtx` (needed for the primitive-array
copy-loop machinery D-progress-887/888 added), but an explicit `return
expr;` statement anywhere else in the same method body is lowered by a
separate code path that was never updated, leaving the identical bug
reachable via a different statement shape.

**Root cause.** `SReturn` (`05_stmts.l`) routes its value through the
shared `coerceValueTo` helper (`06_items.l`), whose non-primitive-array-
widening fallback called the ctx-LESS `coerceArgTo` directly instead of
`coerceArgToCtx` — even though `coerceValueTo` already takes `ctx: in
FuncCtx` as a parameter for its own primitive-array-boxing branch. So an
extern-interface impl method with an explicit early `return` (rather than a
bare tail expression) narrowing a `slice[Byte]`-shaped return reproduced
the exact `VerifyError: Bad return type` D-progress-887 fixed for the
tail-position case. Empirically, only the PRIMITIVE-element narrowing
actually reproduces this way: `coerceArgTo`'s own `ArrayList` -> reference-
array narrowing (added in D-progress-886) needs no `FuncCtx`, so a
reference-typed `slice[ExternType]` explicit return already worked even
through the ctx-less path — confirmed by writing both shapes as regression
cases and reverting the fix as a negative control (only the primitive case
failed).

**Fix.** `coerceValueTo`'s fallback now calls `coerceArgToCtx(ctx, insns,
tailTy, retTy)` instead of the ctx-less `coerceArgTo`. Since `coerceValueTo`
is a single shared helper with nine call sites (explicit `return`, `val`
bindings with a narrower annotation, array-cell assignment, and
constructor-argument coercion), this one change closes the identical latent
gap at every one of those sites, not just the reported `SReturn` shape.

**Verification.** Two new `iface_dispatch_jvm_self_test.l` cases: an
extern-interface impl method with an explicit `return` narrowing a
reference-typed `slice[JX509Certificate]` return, and one narrowing a
primitive `slice[Byte]` return. Reverting the fix and rebuilding reproduces
the exact reported `VerifyError: Bad return type` on the primitive case
only (the reference case passes either way, per the root-cause note above)
— `iface_dispatch_jvm_self_test` 11/12 with the fix reverted, 12/12 with it
restored. No regression: `control_flow_jvm_self_test` (17/17),
`out_inout_jvm_self_test` (18/18), `out_inout_instance_jvm_self_test`
(9/9), `record_method_jvm_self_test` (19/19),
`silent_miscompile_guard_jvm_self_test` (44/44),
`iface_default_method_out_inout_jvm_self_test` (4/4),
`projectable_jvm_self_test` (6/6), `stackmap_expr_branch_jvm_self_test`
(9/9).
