# D-progress-886 — #6995: the value-type flavor of a Gap 1 GENERICINST member parameter is confirmed unreachable today; declined loudly rather than shipped untested

**Status:** shipped

**Context.** `claude-review`'s second pass on PR #6981 (#6581) flagged that
`emitGenericExternMember`'s argument-loading `castclass` (D-progress-883's
Gap 1) only handles `MGenericInst` (the reference-type flavor of a
GENERICINST-shaped member parameter closed over the declaring type's own
VAR) — `MValueTypeGenericInst` (the value-type flavor, e.g. a hypothetical
`KeyValuePair<TKey,TValue>`-shaped ctor parameter) silently falls through
with no `unbox.any`, which would pass a boxed `object` where the CLR
expects an unboxed struct.

**Reachability investigation.** Before implementing `unbox.any` support,
searched for a real BCL API to exercise it (the project's "no test, no
ship" standard). This required tracing every mechanism that can produce
the substituted parameter's shape:

- `mTy` (the member parameter BEFORE substitution) already correctly
  decodes to `MValueTypeGenericInst` from real metadata whenever a BCL
  member's parameter is directly (unwrapped) a struct-headed closed
  generic instantiation, via `genericMemberSigToMsil`'s existing
  `STNamedGenericInst` arm (D-progress-883) — this part works today.
- The blocker is finding a real, ordinarily-nameable BCL member with this
  exact shape. Every generic-declaring-type member considered that takes a
  struct like `KeyValuePair<TKey,TValue>` directly (not wrapped in
  `IEnumerable<...>`/`List<...>`, which route through the ALREADY-WORKING
  `MGenericInst` arm instead, the wrapper being a reference type regardless
  of what's nested inside it) turned out to be an EXPLICIT interface
  implementation (`ICollection<KeyValuePair<TKey,TValue>>.Add` on
  `Dictionary`/`ConcurrentDictionary`), whose MethodDef `Name` in metadata
  is the fully qualified, angle-bracket-and-backtick-bearing interface
  method name — not reachable through `@externTarget`'s plain
  `Type.Member` string form.
- Separately (and this is the actual root finding): `objArgs` — the
  closed instantiation's own type ARGUMENTS, used to substitute `!0`/`!1`
  positions — can currently NEVER itself contain an `MValueTypeGenericInst`
  entry, because all three Lyric-side mechanisms that populate it
  unconditionally tag their result as reference-type-flavored regardless
  of the real CLR type's `vt` bit: `argFqnToMsil` (falls to `MClassRef` for
  anything not an explicitly-listed primitive), `buildValueTaskGenericMsilTypeFromClrFqn`'s
  inner-type handling (always builds `MClassRef` for the `ValueTask<T>`
  inner type, and does not even parse a NESTED bracket suffix correctly —
  a separate, real, pre-existing gap), and `typeExprToMsilCtx`'s
  `TGenericApp` arm's extern-generic-alias fallback (always constructs
  `MGenericInst`, never checking `isValueTypeFqn`). This means even a
  hypothetical reachable member's *nested* type arguments could never
  surface the value-type flavor either.

**Decision.** Rather than ship an `unbox.any`-emitting arm with no way to
verify it against a real repro, declined the shape loudly: a new
`MValueTypeGenericInst` match arm `panic`s with a clear message naming the
target/member and pointing at #6995, mirroring the EXISTING
`isValType and isInstance` precedent (#5809) that already fails this same
function loudly for its OTHER unimplemented shape rather than silently
emitting wrong IL. This was the reviewer's own explicitly-offered
fallback ("if genuinely out of scope for this PR — explicitly decline...
and document/track it the same way Gap 2's value-type-receiver case was
explicitly declined"). The `buildValueTypeGenericInstBlob` helper drafted
alongside the (reverted) `unbox.any` attempt was removed — it exactly
duplicated the already-existing `buildValueTypeGenericInstBlobWithCtx`
(used extensively elsewhere in `codegen.l`) and had no other caller once
the emit path was replaced with a panic.

**Scope note.** This panic is not expected to ever fire in practice today,
precisely because the reachability investigation found no way to trigger
it — it exists as a safety net against silent miscompilation if a FUTURE
change (e.g. fixing the `TGenericApp`/`argFqnToMsil`/ValueTask-inner-type
gaps identified above) ever makes this shape reachable. Implementing
`unbox.any` for real is gated on fixing at least one of those three
prerequisite gaps first, so a genuine repro exists to test against; not
attempted here as it is materially more scope than this PR's Gap 1/Gap 2
fix.

**Verification.** `make lyric` (full rebuild) + `make ilverify` (123 DLLs,
0 errors) + full regression sweep, all green — the panic arm is additive
(a previously-silent `case _ -> ()` no-op) and does not change behavior on
any currently-reachable code path.

**Related:** #6995 (addressed — declined loudly, tracked for a real fix
once a prerequisite gap makes it reachable), #6581/D-progress-883 (Gap 1,
this entry's base), #5809 (the precedent panic pattern this mirrors), PR
#6981.
