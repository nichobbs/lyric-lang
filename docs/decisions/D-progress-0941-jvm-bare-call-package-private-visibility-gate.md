# D-progress-941 — JVM codegen: the bundle-wide bare-call fallback could resolve to a package-private function in an unrelated package (#6853)

**Status:** shipped

**Context.** `Jvm.Bridge`'s bundle-wide `funcSigs` map registers every free
function under a bare (unqualified) key — `decl.name`, plus an
arity-suffixed `decl.name + "@" + arity` — with first-wins collision
semantics, so `resolveGeneralFuncSig` (`04_calls.l`) can look up a bare call
`helper(x)` without knowing which package declared it. This bare fallback
predates the qualified-key fix (#1680) and exists for backward-compat
same-package/unqualified calls. Neither key was ever gated by the
declaration's visibility: a package-private (`func`, no `pub`/`internal`)
function was just as eligible a bare-key candidate as a `pub` one. MSIL
closed the identical gap for its own bundle-wide fallback
(`Msil.Codegen.bundleFuncFqnByName`) in #6850/#6851; #6853 tracked the JVM
analog, found during that review.

**Root cause.** A bare call `helper(x)` whose caller's package and direct
imports don't declare `helper` can still resolve, via `ctx.funcSigs`'s
unscoped bare key, to a package-private `func helper` declared in some
unrelated, never-imported package — a candidate the type checker's own
`checkImportedVisibility`/T0097 gate would reject. First-wins collision
means whichever package happens to be parsed first wins the bare key, so a
legitimate `pub func helper` in an imported package can silently lose to an
unrelated package-private `helper` registered earlier in bundle order.

**Fix — more than a blind visibility gate.** Naively gating the existing
bare keys (`decl.name`, `decl.name + "@" + arity`) on
`decl.visibility == Some(_)`, mirroring MSIL's one-line fix, would have
broken a *legitimate* same-package bare call to a package-private function:
unlike MSIL, the JVM backend has no separate same-package resolution path
for free functions (`resolveGeneralFuncSig`'s bare-call branch consults only
the one shared, bundle-wide `funcSigs` map). So the fix has two parts:

- `collectFileSigsSeeded`'s `IFunc` arm (`06_items.l`) now also registers a
  **package-scoped** key pair — `owner + "::" + decl.name` and
  `owner + "::" + decl.name + "@" + arity` — **unconditionally** (regardless
  of visibility), since same-package access to a package-private function is
  always legal. These can never collide with an unrelated package's scoped
  keys (the `owner` prefix disambiguates), so no first-wins race applies to
  them at all.
- The existing bundle-wide bare keys (`decl.name`, `decl.name + "@" + arity`)
  are now gated on `decl.visibility == Some(_)` — a package-private function
  is no longer a candidate for the unscoped, cross-package fallback of last
  resort, matching MSIL's `bundleCallable` check exactly.
- `resolveGeneralFuncSig` (`04_calls.l`) now checks the caller's own
  package-scoped key (`ctx.pkgName + "::" + funcName[@arity]`) *first*,
  before falling through to the qualified-path and bundle-wide-bare-key
  logic that already existed. `closureInvokeRetType` (used to recover a
  chained call's return-type shape, e.g. `makeAdder(1)(2)`) gets the same
  scoped-key-first lookup, since it also queries `ctx.funcSigs` by bare name
  and would otherwise silently lose closure-return-type recognition for a
  same-package package-private higher-order function once the plain bare
  key stopped being registered for it.

**Verification.** Two new cases in `jvm_cross_package_collision_self_test.l`:
a direct mirror of MSIL's #6851 test (a package-private `XPriv.Priv.helper`
registered first, a legitimate `pub XPriv.Sub.helper` reachable only through
an imported facade, entry package calls `helper` bare — must resolve to the
`pub` target, never the package-private one), and a same-package regression
case (a package-private `helper` called bare from within its own declaring
package must still resolve, proving the package-scoped key preserves the
pre-existing legitimate behavior the naive MSIL-style fix would have
broken). No regression: `jvm_cross_package_collision_self_test`,
`jvm_registry_rollback_self_test`, `jvm_stdlib_compiled_bundle_self_test`,
`jvm_manifest_package_cycle_self_test` all green.
