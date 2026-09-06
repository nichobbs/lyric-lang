# D-progress-892 — `emitGenericMethodExternCall`'s missing `decl.isAsync` handling declined loudly, not silently, after the silent fallback proved unsafe (#7022)

**Status:** shipped

**Context.** `claude-review`'s next pass on PR #6981 (#6581) flagged that
`emitExternTargetBody`'s `msig.isGeneric` branch (Gap 2, D-progress-886)
never checked `decl.isAsync` — unlike its sibling non-generic branch, which
deliberately keeps the real `Task<T>`/`Task` MemberRef return (`bclRetTy`)
and appends an unwrap sequence for an async wrapper. An `async`-declared
`@externTarget` wrapper over a BCL method that is ALSO generic in its own
right (e.g. `HttpContentJsonExtensions.ReadFromJsonAsync<T>` — a common
ASP.NET Core / EF-Core-style generic async extension method, exactly the
shape Gap 2 was built to support) took the MethodSpec-only
`emitGenericMethodExternCall` path instead, which has no
`Task<T>`/`ValueTask<T>`-unwrap machinery at all: it always emits a
synchronous body pushing the raw `Task<T>` where the caller expects the
already-unwrapped `T` — #7022.

**First attempt (rejected): silent decline.** The reviewer's own suggested
fix offered two options: decline (return `false`) when `decl.isAsync`, or
extend `emitGenericMethodExternCall` to build the correct witness + unwrap.
The first, cheaper option was tried first: gate the `msig.isGeneric` branch
on `and not decl.isAsync`, leaving `resolvedMethodParams`/`resolvedMethodRet`
unset (as if metadata resolution found nothing) for the async+generic
combination, so control falls through to the pre-existing plain-method path.

This was verified NOT to fail cleanly. Before this PR, `resolvedSigToMsil`
had no `STMVar` arm, so a bare `!!n` parameter/return failed conversion
outright (`convOk = false`) and metadata-direct resolution for this whole
combination was skipped, falling back further to the "legacy guess" path.
But THIS PR added the `STMVar` arm (D-progress-886, Gap 2's own base) — so
routing an async+generic call into the plain-method branch now
successfully (but incorrectly) converts the method's own generic positions
and builds a syntactically valid but UNINSTANTIATED MemberRef (no
MethodSpec witness). The build succeeds, but the CLR can't resolve the real
generic method at that signature: a `Task.FromResult<T>`-wrapping async
extern, built as a self-test with this "silent decline" in place, compiled
clean and then threw `System.MissingMethodException` at runtime — a
confusing failure mode traded for a different confusing failure mode, not
a real fix.

**Fix: decline LOUDLY instead.** Mirrors the `#5809`/`#6995` precedent
already established in this same PR: a clear build-time `panic` naming the
target/member and the unsupported shape, contained by `Lyric.Emitter`'s
`msilBridgePanicDiagnostic` boundary into a structured diagnostic (never
thrown to the caller) — a safe, diagnosable failure at compile time instead
of a confusing exception at runtime. Filed #7023 to track the real fix
(extending `emitGenericMethodExternCall` with a `Task<T>`/`ValueTask<T>`
MethodSpec witness plus the unwrap sequence the plain-method async branch
already has).

**Test.** The (now-incorrect) positive-assertion test drafted alongside the
first attempt was removed from `generic_extern_methodspec_self_test.l` — a
bad `@externTarget` like this can't be declared at that file's own top
level, since the panic fires during codegen of the whole test module and
would abort the entire `lyric test` run rather than fail one assertion.
Added a proper negative test to `generic_extern_valuetype_instance_self_test.l`
instead, reusing its existing `Lyric.Emitter.emitProject`-based harness
(mirrors that file's existing `#5809` test exactly): compiles a tiny
`Task.FromResult<T>`-wrapping async-extern fixture in-process, asserts the
panic is contained (no thrown `Bug`), no output artifact is produced, and
the diagnostic text names the unsupported shape.

**Verification.** `make lyric` (full rebuild) + `make ilverify` (123 DLLs,
0 IL-validity errors) + full regression sweep, all green:
`generic_extern_methodspec_self_test.l` (5/5, the incorrect test removed),
`generic_extern_valuetype_instance_self_test.l` (2/2, both decline tests,
run with `LYRIC_LOAD_COMPILER=1`), `typed_ffi_delegate_self_test.l` (5/5),
`msil_project_bridge_self_test.l` (56/56), `mono_self_test.l` (82/82),
`generic_extern_self_test.l` (7/7), `auto_ffi_self_test.l` (23/23),
`nested_generic_self_test.l` (8/8), `cross_package_generics_self_test.l`
(10/10), `msil_restored_bridge_self_test.l` (6/6).

**Related:** #6581/D-progress-886 (Gap 2, this entry's base), #7022
(fixed by this entry), #7023 (the real fix, tracked separately), `#5809`/
`#6995` (the decline-loudly precedent this entry's fix mirrors), PR #6981.
