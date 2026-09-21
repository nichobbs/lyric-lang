# D-progress-941 — `emitGenericAsyncMethodExternCall`: MethodSpec + Task<T>-unwrap for a generic async BCL extern (#7023)

**Status:** shipped

**Context.** D-progress-935 (#7022) declined an `async`-declared
`@externTarget` wrapper over a BCL method that is ALSO generic in its own
right (e.g. `Task.FromResult<TResult>(TResult): Task<TResult>`, or the
heavier real-world `HttpContentJsonExtensions.ReadFromJsonAsync<T>`) with a
loud build-time `panic`, because neither existing codegen path was correct
for the combination: `emitGenericMethodExternCall` (D-progress-929, #6581
Gap 2) builds the MethodSpec instantiation a method-own-generic BCL call
needs but has no `Task<T>`-unwrap logic at all (it always emits a
synchronous `ret` straight off the call); the plain (non-generic)
`decl.isAsync` branch in `emitExternTargetBody` has the unwrap logic but
builds a plain, non-instantiated MemberRef that a method-own-generic BCL
member cannot bind against. This entry implements the real fix.

**Fix.** New sibling function `Msil.Codegen.emitGenericAsyncMethodExternCall`
combines both halves:

1. Resolve the BCL method's params/return via the existing
   `resolvedSigToMsil` (unchanged — its `STNamedGenericInst` arm already
   recurses through `sigMVarIndex`, so `Task.FromResult<TResult>`'s return
   decodes directly to `MGenericInst(Task`1, [MMethodTypeVar(0)])` with no
   new decoding needed).
2. Build the OPEN generic-method MemberRef via the existing
   `buildOpenGenericMethodSigCtx` (the return slot correctly encodes
   `Task`1<!!0>` since `bufFfiType`/`bufMsilType` already recurse into
   `MGenericInst` type arguments, including `MMethodTypeVar`).
3. Witness every one of the method's own generic parameters with
   `System.Object` via a MethodSpec (table 0x2B) — the same erasure
   convention `emitGenericMethodExternCall` already applies — so the type
   the CLR actually instantiates is `Task`1<Object>`.
4. Compute that CLOSED shape at the `MsilType` level with a new helper,
   `eraseMethodTypeVarsToObjectMsil` (substitutes every `MMethodTypeVar`
   with `MObject`, mirroring `substituteTypeVarsMsil`'s existing shape but
   for the method-generic axis), because a TypeSpec blob may only
   reference `!!n` from inside the OWNING generic method's own body — the
   unwrap TypeSpec, built from the CALLER's (non-generic) body, must be
   built against the witnessed `Task`1<Object>`, not the open `Task`1<!!0>`.
5. Append the Task/Task`1<T>`-unwrap sequence against that closed shape
   (`Task::Wait()` for a void task, `Task`1<Object>::get_Result()` via a
   TypeSpec-parented MemberRef otherwise), then the same null-guarded
   `unbox.any`/`castclass` return-narrowing dance
   `emitGenericMethodExternCall` and D-progress-936 already apply for a
   directly-erased generic return — reused here for the unwrapped `Task`
   inner value instead of a bare method return.

`emitExternTargetBody`'s `msig.isGeneric and decl.isAsync` branch now calls
this function first and only panics (with an updated message) when it
declines — matching `emitGenericMethodExternCall`'s "decline, don't panic"
contract at the leaf and only escalating to a build-time diagnostic at the
caller, exactly as the non-async Gap 2 branch already does one branch
above.

**Scope: `ValueTask`1<T>` declined, not attempted.** Only a BCL return of
bare `Task` (void) or `Task`1<T>` (value) is supported — matching the
PRE-EXISTING scope of the plain (non-generic) `decl.isAsync` branch, which
is ALSO hardcoded to `Task`/`Task`1<T>` (`emitExternTargetBody`'s
`bclRetTy` construction has never supported a `ValueTask`-returning BCL
method, generic or not). A `ValueTask`1<T>` return additionally needs the
call's result — a STRUCT, not a reference — staged through a scratch local
(`ldloca`) and a non-virtual `call` to invoke `get_Result()` on it, which
is related to but distinct from the value-type-RECEIVER handling #5809
already covers (a value-type RETURN position, not a value-type RECEIVER
position). `emitGenericAsyncMethodExternCall` declines cleanly (returns
`false`, which the caller turns into the same clear build-time panic) for
this and any other shape outside scope, rather than attempting a
half-verified struct-return path in this change. Filed #7148 to track
`ValueTask`1<T>` support as a scoped follow-up.

**`HttpContentJsonExtensions.ReadFromJsonAsync<T>` not additionally
verified.** The issue's own text flags this as the heavier, more
representative real-world case but explicitly allows scoping it out if it
needs infrastructure beyond the issue (an `HttpContent`/`HttpClient`
fixture, and a real network or loopback-server round trip to produce one).
`Task.FromResult<TResult>` — the issue's own "simplest available" example
— exercises the identical codegen path (a non-generic-declaring-type
static BCL method with its own generic parameter, returning `Task<T>`);
`ReadFromJsonAsync<T>`'s only incremental risk is an instance-vs-static
calling convention difference, which `emitGenericAsyncMethodExternCall`
already handles identically to `emitGenericMethodExternCall`'s existing,
separately-tested instance path (D-progress-937, #7137). Left as a
lower-priority follow-up rather than blocking this fix on new test
fixture infrastructure.

**Test.** `generic_extern_valuetype_instance_self_test.l`'s decline test
for this shape ("async extern wrapper over a BCL method with its own
generics fails the build cleanly … (#7022)") is replaced with a positive,
end-to-end test: it builds the `Task.FromResult<T>`-wrapping
`fromResultAsync` fixture via `Lyric.Emitter.emitProject`, asserts the
build now SUCCEEDS (an output DLL is produced, no panic-diagnostic), then
actually EXECUTES the produced DLL via `dotnet exec`
(`Std.ProcessCapture.runCaptureWithDiagnostics`, the same pattern
`cross_package_generics_self_test.l` already uses) and asserts its stdout
is `42` — proving the MethodSpec-instantiated call and the unwrap sequence
produce the correct runtime value, not just a clean build.

**Verification.** Full clean rebuild (`rm -rf .bootstrap/stage1
bootstrap/src/Lyric.Cli.Aot/bin bootstrap/src/Lyric.Cli.Aot/obj && make
lyric`), then `generic_extern_valuetype_instance_self_test.l` (3/3, the
two pre-existing decline tests still passing plus the new end-to-end
success test), `generic_extern_methodspec_self_test.l`,
`generic_extern_self_test.l`, `nested_generic_self_test.l`,
`auto_ffi_self_test.l`, `async_spawn_self_test.l`,
`cross_package_generics_self_test.l`, `msil_restored_bridge_self_test.l`,
`msil_project_bridge_self_test.l`, `mono_self_test.l` — all green.

**Related:** #7023 (fixed by this entry), D-progress-935/#7022 (the
interim decline this entry replaces), D-progress-929/#6581 Gap 2 (the
MethodSpec-only path this entry extends), D-progress-936 (the
return-narrowing dance reused here), D-progress-937/#7137 (the
instance-path coverage this entry's instance handling piggybacks on),
#5809/#6995 (the decline-loudly precedent for what remains out of scope),
#7148 (the filed `ValueTask<T>` follow-up), `docs/59-compiler-stdlib-deep-review.md`
(the FFI capability matrix this closes one more async/generic gap in).
