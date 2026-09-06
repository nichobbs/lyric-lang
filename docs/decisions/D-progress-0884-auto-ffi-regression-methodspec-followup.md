# D-progress-884 — #6581 follow-up: a genuine `auto_ffi_self_test.l` regression (over-broad `STNamedGenericInst` scoring) plus two review-flagged `emitGenericMethodExternCall` gaps (#6987, #6989)

**Status:** shipped

**Context.** After D-progress-883 landed as PR #6981, `claude-review` posted
two REQUIRED findings against Gap 2's `emitGenericMethodExternCall`
(#6987, #6989, both below). Independently, while investigating a THIRD
issue in this same group (#6029/#5525/#3369/#4601), a genuine regression in
D-progress-883's own `scoreSigType` change was discovered and fixed first.

**Regression 1 — `scoreSigType`'s `STNamedGenericInst(_, _, _) -> 0` arm
matched every CLOSED generic instantiation, not just the declaring-type's-
own-open-VAR shape it was meant for.** `auto_ffi_self_test.l`'s "auto-FFI
resolves inherited instance members through the Extends chain" test
(`w.WriteLine("-line")` on `System.IO.StringWriter`, inherited from
`TextWriter`) started failing with "does not match any instance method…".
Root cause, isolated by bisection (full independent rebuilds in three
isolated `git worktree`s — clean `origin/main`, this branch, and `origin/
main` with only the suspect one-line arm patched in — since a `stage1-fast`-
only rebuild does NOT refresh `./bin/lyric`'s baked-in MSIL backend logic,
confirmed empirically before committing to this method): `TextWriter`
declares `WriteLine(ReadOnlySpan<char>)` among its 20-ish `WriteLine`
overloads. `ReadOnlySpan<char>` decodes to a genuinely CLOSED
`STNamedGenericInst("System.ReadOnlySpan\`1", true, [STPrim(Char)])` — no
VAR/MVAR anywhere in it — yet D-progress-883's arm scored ANY argument
against it as `0` (the same weak-but-nonnegative score as the correct
`WriteLine(string)` candidate's exact match minus the `1000000` exact-arity
bonus each still carries separately), spuriously admitting an unrelated,
type-incompatible overload into the scored candidate pool. In THIS specific
case the correct candidate's higher total score (`1000002` vs `1000000`)
still won, so the regression was not a wrong-overload pick here — but
`resolveExtern`'s two-pass split (D-progress-883's own comment on
`scoreSigTypeWithBases` notwithstanding) requires the noBases pass to
resolve unambiguously, and something in that broadened candidate pool caused
the walk to come back empty instead. (The precise final trigger inside
`resolveOverloadInBases`'s per-candidate loop was not re-derived after the
fix — the fix itself, and the bisection proving it root-causes the failure,
were verified sufficient; not tracked further since the fix closes the
regression cleanly.)

**Fix.** Added `sigIsOpenGeneric`/`sigArgsContainOpenGeneric` (`lyric-
compiler/msil/metadata_reader.l`): a recursive check for whether a
`SigType` still contains an unresolved `STVar`/`STMVar` anywhere (through
`STSzArray`/`STArray`/`STByRef`/`STPtr`/`STGenericInst`/
`STNamedGenericInst` nesting). `scoreSigType`'s arm is now `case
STNamedGenericInst(_, _, args) -> if sigArgsContainOpenGeneric(args) { 0 }
else { -1 }` — scoring 0 only when the instantiation still references an
open VAR/MVAR (the genuine Gap-1 "closed over a concrete instantiation, CLR
accepts anything" case), falling through to ordinary `-1` (real structural
mismatch) for a fully closed, concrete BCL type like `ReadOnlySpan<char>`.
Verified via the SAME three-worktree bisection methodology: the patched
clean-`main` build (this ONE additional check on top of the original
one-line arm) restores all 23/23 `auto_ffi_self_test.l` passes.

**Review finding #6987 — `emitGenericMethodExternCall`'s blob-interning key
collides across distinct declaring types.** `ctxInternBlob`/`internBlob`
(`lyric-compiler/msil/heaps.l`) dedupes strictly by KEY STRING — a second
call under an already-seen key returns the FIRST blob's bytes regardless of
whether the new bytes differ. `openKey` was `"openm_" + emitMember + "_" +
genParamCount + "_" + paramCount` — no declaring-type discriminator, so two
DIFFERENT non-generic-declaring types with a same-named, same-arity,
same-genParamCount static generic method (concretely: `Enumerable.
Empty<T>()` vs `Array.Empty<T>()`, both zero-arg/one-genparam/static)
collide, and whichever compiles SECOND silently gets the FIRST's MemberRef
signature bytes. **Fix:** prepend `toString(parentRow)` (the resolved
declaring type's own TypeRef row, unique per distinct type) to `openKey`.
Regression test: both methods declared and called in the SAME compiled
module (`generic_extern_methodspec_self_test.l`, "Array.Empty<T>() alongside
Enumerable.Empty<T>() does not collide").

**Review finding #6989 — no box/unbox at a method-own-generic
(witnessed-as-`Object`) position.** The MethodSpec built by
`emitGenericMethodExternCall` always witnesses every one of the method's
own generic parameters with `System.Object` (the erasure convention). A
Lyric wrapper argument/return that is a genuine (non-erased) BCL value type
at such a position needs a `box`/`unbox.any` at the call boundary — without
it, the CLR verifier rejects the unboxed value type where the
witnessed-Object position expects a reference (`InvalidProgramException` at
load time). **Fix:** mirrors `emitGenericExternMember`'s existing box/unbox
dance exactly — a `boxIfNeededMsil` call is inserted after `ldarg` for each
declared parameter whose corresponding `mParams[i]` is `MMethodTypeVar` and
whose Lyric-declared type `isValueType`; a null-guarded
`MDup`/`MBrTrue`/`MUnboxAny` sequence (identical structure to
`emitGenericExternMember`'s `retIsTypeVar` handling, #2972) runs before
`MRet` when the return is `MMethodTypeVar` and the Lyric-declared return
`isValueType`. Building the test surfaced a SECOND, independent latent gap
in the same family: `scoreSigType` had no `STMVar` arm at all (only the
`STVar` — declaring-type-VAR — counterpart existed), so `Enumerable.
Repeat<TResult>(TResult element, int count)`'s bare-MVAR first parameter
scored `-1` unconditionally and the scored resolver never found ANY match,
silently falling back to the unscored hint-less legacy path (an F0027
warning, then a `MissingMethodException`-shaped `T0120` at codegen) instead
of ever reaching the new box/unbox logic. Added `case STMVar(_) -> 0`
alongside the existing `STVar(_) -> 0` arm, same weak-but-nonnegative
rationale. Test-method choice note: `System.Activator.CreateInstance<T>():
T` was tried first for the return-unbox case and REJECTED after it failed
with a genuine runtime `InvalidCastException` (not a fix bug) —
`CreateInstance<T>`'s BEHAVIOR, not just its representation, depends on the
real `T` (it literally constructs `new T()`), so witnessing `T=Object`
constructs an actual `new object()` rather than `default(int)`; this is a
fundamental semantic incompatibility with the whole "witness as Object"
strategy for ANY method whose logic branches on `T`'s identity (the same
class of limitation the original PR's doc comment already flagged for
constraint satisfaction, just for a different reason). Replaced with
`System.Linq.Enumerable.First<TSource>(IEnumerable<TSource>): TSource`
chained onto `Repeat`'s own output (both declared via the same
`IEnumerableOfT[T]` extern-type alias, avoiding any cross-alias upcast
question) — `First<T>` merely relays an already-boxed element the caller's
own erased collection already stores as `object` (matching #4601's
erasure convention), so witnessing it as `Object` changes nothing about
which value comes back, and the round-tripped value (`42`) is directly
assertable. This required extending `resolvedSigToMsil`'s existing
`sigNamedGenericInstParts` arm's recursion — already present, unmodified —
to correctly resolve a nested `STMVar` inside `IEnumerable<TSource>`;
empirically confirmed already correct (no code change needed there), since
`resolvedSigToMsil` recurses into itself for generic-instantiation args and
its own top-of-function `STMVar` arm (D-progress-883, this PR's Gap 2 base)
already covers the nested case.

**Verification.** `make lyric` (full stage1 + AOT) after every change in
this entry (`stage1-fast` alone does not refresh the MSIL backend logic
`./bin/lyric` bakes in — confirmed the hard way via the bisection above);
`make ilverify` clean (123 DLLs, 0 IL-validity errors) on the final state;
full regression sweep green: `auto_ffi_self_test.l` (23/23, including the
previously-regressed inherited-member test), `generic_extern_methodspec_
self_test.l` (4/4, all new + original cases), `generic_extern_self_test.l`
(7/7), `generic_extern_valuetype_instance_self_test.l` (1/1),
`nested_generic_self_test.l` (8/8), `mono_self_test.l` (82/82),
`cross_package_generics_self_test.l` (10/10), `msil_restored_bridge_
self_test.l` (6/6), `msil_project_bridge_self_test.l` (53/53).

**Related:** #6581 (D-progress-883, this entry's base), #6987 (fixed),
#6989 (fixed), `auto_ffi_self_test.l` (the regression this entry fixes,
no tracking issue — caught before merge), PR #6981 (the claude-review
findings this entry responds to).
