# D-progress-887 — `Lyric.HoistEngine` resolves an `impl` block's target type's fields across file/package boundaries, closing a cross-file stale-read gap in the await/`?` hoist (#6702)

**Status:** shipped

**Context.** `hzImplTargetFieldNames` (`hoist_engine.l`) resolves an `impl
<Iface> for <Target> { ... }` block's own field names — needed so
`hzNameLikeMutable`'s bare-implicit-self-field case (#6684) can tell a `var`
field write from an immutable local — by scanning the SAME `SourceFile` being
hoisted for a matching `record`/`exposed record`/`protected type`
declaration. When `Target` is declared in a DIFFERENT PACKAGE — a sibling
in-bundle package, a restored dependency, or a stdlib record — the scan
found nothing and silently returned an empty field set. (A *multi-file*
package's own files are concatenated into one `SourceFile` before
`pipeCheckAndMono`/`pipeWeave` ever run, per docs/19 — so a record and an
`impl` in two files of the SAME package were already found by the original
same-file scan; that shape was never the gap.) This was the same
#5629/#6600/#6684
stale-receiver-read bug one file boundary further out: a bare field mutated
by an awaited (or `?`-propagated) call during the hazard was never
hoist-protected, so the read after the hazard observed the POST-mutation
value instead of the value captured before the hazard ran.

**The fix.** `HoistState` gained a new `typeFieldIndex: Map[String,
Map[String, Bool]]` field — a name → own-field-name-set index built once per
`hoistFile` call (`hzBuildTypeFieldIndex`) from the file's own top-level
items PLUS a new `extraRecords: in List[RecordDecl]` parameter threaded all
the way from the public entry points (`hoistFile`, `AwaitHoist.hoistAwaitsFile`)
down to `hzImplTargetFieldNames`, which now looks the target up in this index
instead of re-scanning `file.items`. `pipeWeave` (`pipeline.l`) — the
`AwaitHoist` call site — now takes the same `extraRecordDecls` parameter and
forwards it into the hoist; `pipeMiddleEnd` forwards its own already-computed
`monoRecordDecls` (the monomorphizer's cross-package record list, no new
computation) straight through. `msil/bridge.l`'s two direct `pipeWeave` call
sites (single-file and multi-package project) pass `stdlibRecs` and
`allImportedRecordDecls` respectively — both already-computed lists reused
from the immediately-preceding `pipeCheckAndMono` call, so the fix is
additive plumbing, not new cross-package data collection. `typeFieldIndex`
is threaded through `HoistState` (like `moduleValNames`, #6734) rather than
passed as a side parameter to `hzRewriteItem`, so a nested `impl` block
declared inside a function body (previously hard-blocked at `None`) resolves
against the SAME index too — a strict improvement, not just the top-level
case #6702 was filed against.

`?`-hoisting (`Lyric.Propagate.hoistPropagateFile`) runs earlier in the
pipeline (`pipeCheckAndMono`, before mono, so before `monoRecordDecls` is
even assembled for that file) and keeps passing an empty `extraRecords` list
— its cross-file gap is unchanged and narrower in scope than #6702's own
plan (which named `pipeWeave`'s `AwaitHoist` invocation specifically); the
shared engine fix is available to close it too whenever that's prioritized.

**Verification.** New AST-level regression test in
`propagate_hoist_entry_polarity_self_test.l` — a genuine two-`SourceFile`
simulation (a record declared in one parsed source, never merged into the
`impl`'s own parsed source — the genuine cross-PACKAGE shape, distinct from a
multi-file package's own files, which are merged before this pass ever runs)
proves both
directions: with `extraRecords` empty the `impl` method's body stays at 2
statements (only the hazard hoists; the receiver stays an unprotected bare
read — the pre-fix gap, reproduced), and with the library's `RecordDecl`
supplied via `extraRecords` the body grows to 3 statements (receiver AND
hazard both hoisted, matching the existing same-file #6684 shape) — 5/5.
No regressions: `await_hoist_self_test.l` 19/19, `propagate_hoist_self_test.l`
42/42, `async_sm_self_test.l` 71/71, `async_spawn_self_test.l` 26/26,
`async_generator_self_test.l` 16/16, `bitwise_self_test.l` 10/10,
`aspect_weave_self_test.l` 13/13.

**Related:** #6702, #6684, #6600, #6734, #6787 (a separate, downstream MSIL
async-SM codegen bug discovered alongside #6702 in the same investigation —
filed and tracked independently; re-verified fixed on current `main`, see
that issue's closing comment), docs/19 (multi-file packages).
