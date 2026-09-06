# D-progress-887 — `emitGenericMethodExternCall`'s `openKey` folds full structural type encoding, closing the intra-type overload-collision variant (#7016)

**Status:** shipped

**Context.** D-progress-884 fixed #6987 by prepending `parentRow` (the
resolved declaring type's own TypeRef row) to `emitGenericMethodExternCall`'s
`openKey`, so two DIFFERENT declaring types' same-named/same-arity/
same-genParamCount generic methods no longer collide. `claude-review`'s
next pass on PR #6981 (#7016) found the fix incomplete: `openKey` still
encoded only `parentRow + emitMember + genParamCount + paramCount` — pure
counts, no actual parameter/return TYPES. Two overloads on the SAME
declaring type sharing all four of those (a real BCL example:
`Enumerable.ElementAt<TSource>(IEnumerable<TSource>, int)` vs the
`System.Index`-taking overload added alongside Ranges — both static, one
genparam, two ordinary params, same declaring type `Enumerable`) still
produced an identical key string, so `ctxInternBlob`/`internBlob`'s
strict-by-key-string dedup let whichever overload compiled second silently
reuse the first's MemberRef signature bytes — a load-time fault or a
wrong-overload resolution, not a build-time error.

**Fix.** Folded each parameter's and the return's full `msilTypeKeyStr`
structural encoding into `openKey`, mirroring the Gap 1 `castclass` cache
key (`ts_genarg_` + `msilTypeKeyStr(mTy)` + `objArgsKey`) already used
elsewhere in the same file for exactly this reason — full structural
serialization, not just counts, so two signatures that differ in any
parameter or return type never share a cache key regardless of how many
counts happen to coincide.

**Verification.** New regression test in
`generic_extern_methodspec_self_test.l`: `Enumerable.ElementAt<TSource>
(int)` vs `ElementAt<TSource>(System.Index)`, both wrapped as
non-generic `@externTarget` functions and both called against the same
`IEnumerableOfT[String]` source (constructed via the already-proven
`Enumerable.Repeat<T>` path) in the same compiled module — deliberately
delegate-free, since an earlier `Enumerable.Select<TSource,TResult>`
attempt (two-arg selector vs the indexed three-arg selector overload) was
found to hit an unrelated, pre-existing gap in scoring a `Func<...>`-typed
extern parameter against its BCL overload set (same family as #5800/#5947,
not this issue). `make lyric` (full stage1 + AOT) + `make ilverify` (123
DLLs, 0 IL-validity errors) + full regression sweep, all green:
`generic_extern_methodspec_self_test.l` (5/5), `msil_project_bridge_
self_test.l`, `mono_self_test.l` (82/82), `generic_extern_self_test.l`
(7/7), `generic_extern_valuetype_instance_self_test.l` (1/1),
`auto_ffi_self_test.l` (23/23), `nested_generic_self_test.l` (8/8),
`cross_package_generics_self_test.l` (10/10), `msil_restored_bridge_
self_test.l` (6/6).

**Related:** #6581/D-progress-883 (Gap 2, this entry's base), #6987/
D-progress-884 (the cross-declaring-type variant of this same collision
class, fixed first), #7016 (fixed by this entry), PR #6981.
