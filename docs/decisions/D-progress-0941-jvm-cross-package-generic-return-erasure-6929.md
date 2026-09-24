# D-progress-941 — JVM cross-package generic-function return-class resolution (#6929)

**Status:** shipped

**Context.** Issue #6929: on the JVM backend, a field read on a local
bound to a *cross-package* generic function's call result silently
erased to `Object`. Repro shape (three packages, so the callee's own
package shares a file with neither the record's declaring package nor
the caller):

```
package EntryPkg
pub record Entry[K, V] { key: K, value: V }

package MakerPkg
import EntryPkg
pub func makeEntry[K, V](k: K, v: V): EntryPkg.Entry[K, V] {
  EntryPkg.Entry(key = k, value = v)
}

package App
import MakerPkg
import EntryPkg
func main(): Int {
  val e = MakerPkg.makeEntry(1, 42)
  println(e.value)   // erased-Object miscompile before this fix
  0
}
```

`Jvm.Codegen.recordRetClassOf` (`codegen/01_types.l`, #6399) resolves a
function's declared return type to its raw class only when the record
is declared in the SAME FILE as the function — a same-file pre-scan run
at `collectFileSigsSeeded`'s signature-collection time
(`Jvm.Bridge`). A record declared in a DIFFERENT file (its own package,
or a third package entirely, as in the repro above) was unresolvable
there: doing so needs the bundle-wide constructor registry (`ctorReg`),
which was only PARTIALLY populated at that point, because the original
registration order interleaved `collectFileSigsSeeded` and
`collectFileCtors` per file — `collectFileSigsSeeded(userFile, ...)` ran
before ANY `collectFileCtors` call for a cross-package file had a chance
to run. The field read fell through to the erased-`Object`
bundle-wide `field:<name>` fallback, risking a silent wrong-class
resolution exactly like #6691/#6708's own failure mode (see
D-progress-878).

**A second, initially-missed registration path.** The obvious fix
(reorder ctor registration + add a bundle-wide fallback consulted from
`collectFileSigsSeeded`) fixed the direct case but the repro above kept
failing with the same `J007` erasure error. Debug instrumentation
(temporary `Std.Console.error` prints in `recordRetClassOfBundleTe` and
`lowerGeneralStaticCall`) traced the actual call site to a
*mono-specialised* signature (`makeEntry__Int__Int`), not the original
generic one: `Lyric.Mono` DOES monomorphize a cross-package call — its
call-site walk infers concrete type arguments from the CALLER's
literals and isn't restricted to the callee's own file — and a
specialised copy's signature is registered via a wholly separate
function, `Jvm.Bridge.collectMonoSpecializedSigs`, never through
`collectFileSigsSeeded` at all. `collectMonoSpecializedSigs` had a
hardcoded `recordRetClass = None` with the comment "no local-record
scan available here," so the new bundle-wide fallback was invisible to
any call site that got monomorphized — which every literal-argument
call to a generic function does. Both registration paths needed the
fix.

**Fix.**

1. **`Jvm.Codegen.recordRetClassOfBundle`** (new, `codegen/01_types.l`)
   — a bundle-wide fallback consulted when the same-file
   `recordRetClassOf` scan misses, resolving through the (now
   fully-populated) `ctorReg` the same way `recordParamClassOf`'s
   `ctorClassFor` lookup already does for parameters. Its type-expr
   helper (`recordRetClassOfBundleTe`) handles both a `TGenericApp`
   head and a bare `TRef` head — the latter needed because `Lyric.Mono`
   can substitute a specialised function's return type down to a bare
   non-generic reference (no generic params left on the specialisation
   to re-apply type args to), not just erase the args of a
   `TGenericApp`. A shared helper (`recordRetClassOfBundleHead`)
   resolves single-segment heads via a new `ctorClassForBundle`
   (owner-scoped-first, mirroring `ctorClassFor`'s `ctx.ctors` pattern)
   and multi-segment/qualified heads via the dotted key `addCtorKeys`
   already registers.

2. **Registration-order fix in `Jvm.Bridge.compileProjectToJarBundledWithRestored`**
   (`bridge.l`) — hoisted every `collectFileCtors` call (user file, all
   stdlib files, all restored artifacts) into a single pre-pass that
   runs BEFORE any `collectFileSigsSeeded` call, replacing the previous
   per-file interleaved order. `collectFileCtors` has no dependency on
   the signature registry, so this is a pure reordering: `ctorReg` is
   now fully populated before `recordRetClassOfBundle`'s fallback is
   ever consulted, for the user file, every stdlib file, and every
   restored artifact alike. `collectFileSigsSeeded` gained a `ctorReg`
   parameter (threaded from `collectFileSigs`'s wrapper with an empty
   map, and from all three real call sites with the bundle-wide one)
   consulted only when the same-file `localRecordNames` scan misses.

3. **`Jvm.Bridge.collectMonoSpecializedSigs`** — threaded the same
   `ctorReg` parameter through (both call sites: the main post-mono
   registration and the sibling-project-package post-weave
   registration), and changed its `recordRetClass = None` to
   `recordRetClass = recordRetClassOfBundle(decl.ret, owner, ctorReg)`.
   A mono-specialised function's own declared return type is exactly as
   concrete as its unspecialised original's (Mono substitutes type
   variables, it doesn't invent new ones), so the same bundle-wide
   lookup applies unchanged.

**Regression test.** New
`lyric-compiler/lyric/jvm_generic_call_result_cross_package_self_test.l`
(`@test_module`, driven in-process via `Jvm.Bridge` like
`jvm_cross_package_collision_self_test.l`, run in CI via native
`lyric test`): two cases, a single field read (`e.value`) and a chained
two-field read (`e.key`, `e.value`), both across a three-package split
(entry-record package / generic-maker package / caller package). Both
call sites use literal arguments, so both exercise the
`collectMonoSpecializedSigs` path — the load-bearing one, since it's
the one that was still missed after the first-draft fix.

**Verification.**

- Reverting *only* `collectMonoSpecializedSigs`'s
  `recordRetClass = recordRetClassOfBundle(...)` back to `None`
  reproduces the exact predicted failure on both test cases:
  `error[J007]: App:8:11: member 'value' cannot be resolved on an
  erased (statically Object) receiver` / the analogous `App2:8:11:
  member 'key'` error. Restoring the fix makes both pass again —
  confirms the fix (not just the reordering or the bundle-wide
  fallback alone) is load-bearing.
- Full regression sweep, all green, no collateral damage from the
  ctor-pre-pass reordering: `jvm_cross_package_collision_self_test.l`
  (10/10), `cross_package_generics_self_test.l` (11/11, pre-existing
  unrelated `W0005` MSIL warnings only), `generic_specialization_self_test.l`
  (8/8), `mono_self_test.l` (87/87), `mono_shadow_self_test.l` (5/5),
  `result_generic_specialization_self_test.l` (4/4),
  `stdlib_generic_mono_self_test.l` (7/7), `nat_cross_package_self_test.l`
  (2/2).

**Related:** #6399 (`recordRetClassOf`, the same-file-only precedent
this bundle-wide fallback extends), D-progress-878 / #6691 / #6708 (the
erased-Object field-read failure mode this fix closes another instance
of), #3229 / #3676 (`collectMonoSpecializedSigs`'s original introduction,
for the map-iteration mono-specialization symptom), `docs/44-jvm-production-readiness-plan.md`
(the JVM production-readiness remediation plan this fix's finding
belongs to).

**Follow-up: extern-type bare-name collision regression (#7195).** The
initial review round flagged, as a hypothetical, non-blocking risk
(#7195), that `recordRetClassOfBundle`'s bare-name fallback extends the
already-accepted `recordParamClassOf`/#6691/#6708 cross-package
collision risk to return-type resolution. CI on this PR's own head
turned that hypothetical into a real, reproducible regression: a
pre-existing test, `emitProject alias-qualified GENERIC extern type
signature collision (JVM, TGenericApp)` (`emitter_project_self_test.l`),
started failing with a runtime `ClassCastException`.

Root cause: the test's `Helper` package declares `extern type JDict[K, V]
= "java.util.concurrent.ConcurrentHashMap"` and a same-file function
`newJDict(): JDict[String, String]`. The unrelated `App` package
declares its own `record JDict { tag: String }`. Before this fix,
`newJDict`'s return type resolved via `recordRetClassOf`'s same-file
scan — a miss, since `JDict` is an extern type, not a local record — so
`sigRecordRetClass` stayed `None` (safe erasure). After this fix, the
same miss now falls through to `recordRetClassOfBundle`, whose bare-name
lookup (`ctorClassForBundle`) has no way to know `JDict` is an extern
type in `Helper`'s own scope: it finds the bundle-wide bare key `JDict`
registered by `App`'s unrelated record and wrongly resolves
`newJDict`'s `sigRecordRetClass` to `Alias6338Generic/App/JDict`. Every
call to `newJDict()` then got a bogus `checkcast` to that record's
class, producing `ClassCastException: class ConcurrentHashMap cannot be
cast to class Alias6338Generic.App.JDict` at runtime — the #7195 risk
materializing in practice, and strictly worse than the accepted
`recordParamClassOf` precedent: that precedent risks resolving to the
WRONG record; this one could fire for a type that is not a record at
all.

**Fix.** `recordRetClassOfBundle` (and its `recordRetClassOfBundleTe`
helper) now take the caller's own file-scoped `externTypes` map
(`ownAwareExternTypes(file, externSeed)`, already in scope at both call
sites — `collectFileSigsSeeded` in `06_items.l` and
`collectMonoSpecializedSigs` in `bridge.l`) and check it BEFORE
consulting `ctorReg` for a bare single-segment `TGenericApp`/`TRef`
head: a name that already resolves as a same-file/imported `extern
type` is never a Lyric record, so the bundle-wide fallback returns
`None` (the pre-existing safe-erasure behavior) instead of risking a
bare-name collision. Qualified/dotted heads are unaffected (they were
never subject to the bare-key collision risk in the first place).

**Verification.** `emitter_project_self_test.l` (38/38, including the
previously-failing test 7) and the full original regression sweep
(`jvm_generic_call_result_cross_package_self_test.l` 2/2,
`jvm_cross_package_collision_self_test.l` 10/10,
`cross_package_generics_self_test.l` 14/14,
`generic_specialization_self_test.l` 8/8) all pass with the guard in
place. Closes #7195.
