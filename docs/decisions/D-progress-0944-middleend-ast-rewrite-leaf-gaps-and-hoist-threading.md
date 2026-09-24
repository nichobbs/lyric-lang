# D-progress-944 — Compiler middle-end: mono.l ERange/EForall/EExists/EOld leaf gap, extern-type type arguments, and propagate ?-hoist cross-package threading (#6968, #6891, #6967)

**Status:** Shipped.

**Context.** Three related bugs in the same "middle-end AST-walking pass
treats a form as a leaf, or lacks cross-package information it needs" family,
surfaced by `claude-review` follow-ups and an ecosystem-library PR review.
A fourth issue in the same batch, #7079, turned out to already be fixed
(under #7093, closed during PR #6863's own review cycle) — closed as a
stale duplicate rather than re-fixed.

## #6968 — `Lyric.Mono`'s call-site monomorphizer leaf-treated `ERange`/`EForall`/`EExists`/`EOld`

`mono.l`'s `rewriteExpr` (the call-site monomorphizer's AST walk) had the
identical gap `Lyric.Weaver`'s own `rewriteExpr` had before #6833/#6863: a
generic call site inside a range expression's bound (`for i in 0 ..
genericCall()`) or inside a `forall(...)`/`exists(...)` binder's `where`/body
never got rewritten to its specialised name, leaving a dangling reference to
a generic Phase 2 erases. `QuantifierExpr` (`forall`/`exists`) is
grammar-restricted to `requires:`/`ensures:` clauses, so the only way an
`EForall`/`EExists` node reaches this walker at all is via the contract
elaborator's lowering — confirmed by reading `contract_elaborator/elaborator.l`:
the elaborator preserves the quantifier node (recursing into `whereExpr`/
`body` but keeping the `EForall`/`EExists` wrapper) when it copies a
`requires:`/`ensures:` clause into an inserted `assert(...)` statement, and
`elaborateFile` runs before `monoFile` in `pipeCheckAndMono`.

**Fix.** New `ERange`/`EForall`/`EExists`/`EOld` cases in `rewriteExpr`,
mirroring the weaver's already-fixed shape exactly: a new `rewriteRangeBound`
helper recurses into all four `RangeBound` variants (`RBClosed`/`RBHalfOpen`/
`RBLowerOpen`/`RBUpperOpen`); `EForall`/`EExists` recurse into `whereExpr`/
`body`. `EOld` is included for consistency with every other AST walker in
this codebase (the weaver's own fix includes it too), though it never
actually reaches this walker in practice: the contract elaborator's
`replaceOldExpr` replaces every `EOld(inner)` node with a snapshot-local
`EPath` reference before mono ever sees the body.

## #6891 — generic monomorphization rejected an `extern type` explicit type argument

`indexExprToTypeArgMono` (converts an `f[T, U](...)` bracket-syntax index
expression into type arguments for the call-site monomorphizer) whitelisted
a single-segment name as a legitimate type argument only when it resolved as
a primitive, record, interface, distinct type, or union — never an `extern
type`. A generic function instantiated with an explicit `extern type` type
argument (e.g. `newConcurrentDict[String, JSecretsManagerClient]()`, from a
lyric-aws-secrets JVM kernel client-cache singleton) therefore fell through
as unresolvable, either raising `M0002` ("does not resolve to a known type
in this compilation unit") for a plain dropped generic, or silently leaving
a dangling reference for an `@externTarget`-kept one.

**Fix.** New `externTypeDecls: Map[String, Bool]` field on `MonoState`,
populated from same-package `IExternType` items in the same collection pass
that populates `recordDecls`/`ifaceDecls`/`unionDecls`, and consulted
alongside them in `indexExprToTypeArgMono` — mirroring the `unionDecls`
precedent (#6774) added for exactly this reason for a different item kind.

## #6967 — `Lyric.Propagate`'s `?`-hoist had the identical cross-package gap #6702 fixed for `await`-hoist

`hoistPropagateFile` passed an empty `extraRecords` list to the shared
`Lyric.HoistEngine`, unlike `Lyric.AwaitHoist.hoistAwaitsFile` (fixed for
this in #6702): a bare (implicit-self) field read across a hoisted
`?`-propagation hazard, where the `impl`'s target type is declared in a
different package, was not recognised as hoist-worthy, so the receiver
could observe a stale/wrong value.

**Fix.** Mirrors #6702's shape exactly: `hoistPropagateFile` now takes an
`extraRecords: in List[RecordDecl]` parameter and is `pub` (so a test can
inspect the hoist step directly, matching `hoistAwaitsFile`'s own
visibility). `lowerPropagateFile`'s public entry point splits into a thin
backward-compatible wrapper plus a new `lowerPropagateFileWithExtraRecords`,
keeping all 11 existing call sites unbroken. `pipeline.l`'s
`pipeCheckAndMono` threads its own `monoRecordDecls` parameter through,
mirroring `pipeWeave`'s identical #6702 threading into `AwaitHoist.hoistAwaitsFile`
just below it.

**Verification.** Full `make lyric` build succeeded; `mono_self_test.l`
91/91 (4 new cases for #6968/#6891), `propagate_self_test.l` 17/17 (no
regression from the entry-point split), `propagate_hoist_self_test.l` 42/42
(no regression), `propagate_hoist_entry_polarity_self_test.l` 6/6 (1 new
case for #6967, mirroring that file's own #6702 test — negative control
with no `extraRecords` stays at 2 statements, positive control with
`extraRecords` supplied grows to 3, matching the predicted shape exactly).
`lyric fmt --write` applied to all changed files.

**Related:** #6968, #6891, #6967, #7079 (closed as duplicate of #7093), D-progress-887
(the weaver's own `ERange`/`EForall`/`EExists` fix this mirrors, #6833/#6863),
#6774 (the `unionDecls` precedent #6891's fix mirrors), #6702 (the
`AwaitHoist` fix #6967's fix mirrors).
