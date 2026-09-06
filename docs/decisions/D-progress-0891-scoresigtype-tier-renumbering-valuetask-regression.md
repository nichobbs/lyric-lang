# D-progress-891 — `scoreSigType`'s tier scale renumbered after a real `ValueTask` ctor-ambiguity regression on PR #6981

**Status:** shipped

**Context.** PR #6981 (#6581, D-progress-886/887) added two new weak-but-
nonnegative `scoreSigType` arms — `STMVar` and `STNamedGenericInst` gated
on `sigIsOpenGeneric` — both scored `0`, the same value the pre-existing
`STVar` arm (D-progress-686) already used. The PR's own `build-and-test`
CI job caught the fallout on the current head: `typed_ffi_delegate_
self_test.l`'s two `ValueTask` tests (D-progress-686, #5803/#5833)
started failing with `Unable to cast object of type 'System.IO.
MemoryStream' to type 'System.Threading.Tasks.Task`1[System.IO.Stream]'`.

**Verification this was a real regression, not pre-existing.** Built a
clean `origin/main` in an isolated `git worktree` (the same isolated-
worktree bisection methodology used earlier in this PR's own history) and
ran the identical test: 5/5 pass on unmodified `main`, confirming the
failure was introduced by this branch's changes, not latent on `main`.

**Root cause.** `System.Threading.Tasks.ValueTask<TResult>` has two
same-arity ctors: `.ctor(TResult result)` — a bare declaring-type VAR
(`STVar`) — and `.ctor(Task<TResult> task)` — a CLOSED generic
instantiation (`STNamedGenericInst`) WRAPPING that same VAR. Before this
PR, `STNamedGenericInst` had no scoring arm at all (defaulted to the
catch-all `-1`), so only the bare-VAR ctor scored `>= 0` and was the
unambiguous winner. This PR's new `STNamedGenericInst`-open-var arm
(added to fix #6581 Gap 1's real need — disambiguating e.g. `List`1..ctor
(IEnumerable`1<!0>)` from `.ctor(int capacity)`) also scores `0` for the
`Task<TResult>`-wrapping ctor, recreating a tie with the bare-VAR ctor.
Since both are now "admissible" (`>= 0`), `resolveExternMethodScoredIn`'s
tie-break reverted to Method-table row order — which, for this specific
member, happened to favor the wrong (`Task`-wrapping) ctor for a plain
`MemoryStream` argument that doesn't structurally resemble `Task<T>` at
all.

**Fix.** Renumbered `scoreSigType`'s entire tier scale so each distinct
kind of match gets its own rung instead of two colliding at the same
value:

| Tier | Old | New |
|---|---|---|
| Exact match | 2 | 3 |
| Widening / object-accepts-anything / Extends-chain upcast | 1 | 2 |
| Bare declaring/method-own VAR (`STVar`/`STMVar`) | 0 | 1 |
| Wrapped open-generic instantiation (`STNamedGenericInst`, open) | 0 | 0 |

This preserves every existing relative ordering (exact > widening > VAR
> wrapped) — nothing that used to win now loses — while giving the VAR
tier the headroom it needs to unambiguously outrank the wrapped tier
whenever both are candidates in the same overload set, closing the
`ValueTask` collision without reopening the original #6581 Gap 1/Gap 2
bugs the wrapped tier exists to fix. The universal `-1` "no match"
sentinel, used pervasively by dozens of other match arms in the same
function and checked via `s < 0` throughout the caller chain, was left
completely untouched — an earlier considered alternative (giving the
wrapped tier a negative-but-still-admissible value and loosening the
reject threshold to `< -1`) was rejected specifically because it would
have silently repurposed every OTHER arm's `-1` "hard reject" return
value as "weakly admissible" too, a far larger and more dangerous blast
radius than a scale shift.

Applied consistently across `scoreSigType`, `scoreSigTypeWithBases` (the
Extends-chain upcast path, its own literal bumped from 1 to 2 to match),
and `scoreSigTypeLenient` (the hint-less `@externTarget` path that
`resolveExternMethodScoredIn` actually calls via `scoreParamsLenient` for
ctor resolution — its own weak-match literal also bumped from 1 to 2),
plus the two `== 2` exact-match-dependent call sites (`STSzArray`'s
recursive element check in `scoreSigType` itself, and `argCoercionInsns`
in `codegen.l`), both now `== 3`.

**Verification.** `make lyric` (full rebuild) + `make ilverify` (123
DLLs, 0 IL-validity errors) + full regression sweep, all green:
`typed_ffi_delegate_self_test.l` (5/5, the regressed test, now passing),
`generic_extern_methodspec_self_test.l` (5/5), `msil_project_bridge_
self_test.l` (55/55), `mono_self_test.l` (82/82), `generic_extern_
self_test.l` (7/7), `generic_extern_valuetype_instance_self_test.l`
(1/1), `auto_ffi_self_test.l` (23/23), `nested_generic_self_test.l`
(8/8), `cross_package_generics_self_test.l` (10/10), `msil_restored_
bridge_self_test.l` (6/6).

**Related:** #6581/D-progress-886 (Gap 1's `STNamedGenericInst` arm,
whose introduction created this collision), D-progress-887 (`STMVar`'s
introduction), D-progress-686 (the original `STVar` fix this regression
undermined), PR #6981.
