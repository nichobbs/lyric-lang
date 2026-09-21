# D-progress-940 — Doc-sync follow-up for the MSIL module-val bundle-collision fix (#7097, PR #7100)

**Status:** shipped

**Context.** Issue #7097 reported that two packages in one `lyric.toml`
project each declaring a same-named, non-`pub`, module-level `val` (or
`const`) with a non-literal initializer crashed MSIL codegen with a
contained `error[T0120]: MSIL codegen failed: An item with the same key
has already been added. Key: <name>`. Root cause: `addPackageTokens`
(`lyric-compiler/msil/codegen.l`) registered each non-literal `IVal`/
`IConst`'s bare (package-unqualified) name into `cctx.staticValTokens`
via an unguarded `Map.add`, and `Map.add` (`Dictionary.Add`) throws on a
duplicate key — the second package's same-named `val` crashed the whole
build instead of getting its own field.

The fix already shipped for this exact issue in PR #7100 (merged
2026-09-14, present on `main` at commit `f2718787`), alongside two
unrelated fixes (#7098 `fromJson` panic, #7099 unknown-String-method
silent stub). PR #7100:

- Guards both `IConst`'s and `IVal`'s bare-name registration with
  `containsKey` (first-wins, mirroring the native backend's existing
  `#6224` fix for the identical bare-name-keyed-map pattern in
  `lyric-compiler/lyric/llvm_codegen.l`'s `moduleVals`).
- Fixes the READ side too, which a write-side-only guard would have left
  silently broken: a bare `EPath`/pattern-const reference now checks the
  reading package's own qualified key (`fctx.pkgName + "." + name`)
  FIRST, falling back to the bare (first-wins) key only when the
  reading package has no `val`/`const` of its own by that name — so a
  package always reads its own module-level binding, never another
  package's same-named one via the first-wins fallback. Both the
  `EPath` static-val-load site (`lowerExprMsil`) and the
  `PConstRef` non-integer-const-match site (`lowerPatternTestMsil`)
  got this fix.
- New regression test `"same-named private non-literal module vals
  across packages do not crash MSIL codegen"` in
  `lyric-compiler/lyric/msil_project_bridge_self_test.l`: two packages
  each declare `val label: String = "from-A"` / `"from-B"`, each with a
  `pub func` returning its own package's `label`; asserts exit 0 and
  that each package prints its OWN value (`from-A\nfrom-B`), not a
  collided/shared one.

**What this entry adds.** PR #7100 landed the code fix and the CI-wired
regression test but — per this repo's CLAUDE.md "Keeping docs, book,
and progress records in sync" requirement — never added a decision-log
entry or a `docs/10-bootstrap-progress.md` note, and never referenced
#7097 with a GitHub auto-close keyword the platform recognizes (the PR
body reads "Fixes three self-hosted compiler bugs reported in #7097,
#7098, #7099" — the keyword "Fixes" is not immediately followed by the
issue reference, so GitHub's auto-close regex did not fire and #7097
stayed open despite being fixed). This entry is the CLAUDE.md-mandated
"immediate follow-up... landed before starting the next task" for that
gap; #7097 is closed by hand alongside this PR, referencing PR #7100 as
the actual fix.

**Verification (re-confirmed against the shipped fix, this PR).** Full
clean rebuild (`rm -rf .bootstrap/stage1
bootstrap/src/Lyric.Cli.Aot/{bin,obj} && make lyric`), then:

- The issue's exact repro (`Repro.A`/`Repro.B` each declaring
  `val userAgent = "Repro-A/0.1"` / `"Repro-B/0.1"`, a `pub func`
  returning it, consumed from `Repro`'s `main`) builds and runs clean,
  printing `Repro-A/0.1` then `Repro-B/0.1` (was `error[T0120]` before
  PR #7100).
- `msil_project_bridge_self_test.l` — full suite green on
  `--target dotnet`, including the #7097 regression case.
- `module_val_deps_self_test.l` — full suite green (no collateral
  damage from the qualified-key-first read ordering).
- `--target jvm` unaffected (the JVM backend's `Jvm.Codegen` module-val
  registry was never bundle-wide-bare-keyed the way MSIL's was; no
  change made or needed there).

**No further codegen change was made in this PR** — the underlying fix
is already correct and complete on `main`; see PR #7100's own body for
its full verification account (57/57 `msil_project_bridge_self_test.l`,
51/51 `derives_self_test.l`, 19/19 `module_val_self_test.l`, 9/9
`module_val_deps_self_test.l`, plus `msil_restored_qualified_val_self_test.l`,
`bitwise_self_test.l`, `compound_string_assign_self_test.l`,
`slice_string_self_test.l`, and JVM `string_methods_jvm_self_test.l`).

**Related:** #7097 (closed by this PR, fixed by #7100), PR #7100 (the
actual fix), #6224 (the native-backend `llvm_codegen.l` analog this fix
mirrors), #6849/#6850/D-progress-876 (the `bundleFuncFqnByName` /
`findBundleFqnByName` bundle-wide bare-name-collision precedent for
FUNCTIONS this fix's VAL analog follows the same shape as: register a
qualified key alongside the guarded bare one, prefer the qualified key
on read), #5258 (the pre-existing `pub` module-val qualified-key
convention this fix's read-side ordering builds on).
