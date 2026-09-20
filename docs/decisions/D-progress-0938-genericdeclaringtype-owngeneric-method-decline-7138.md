# D-progress-938 — `emitGenericExternMember` declines loudly for a generic-declaring-type member that ALSO has its own method-level generic parameters (review follow-up, #7138)

**Status:** shipped

**Context.** A `claude-review` pass on PR #6981 flagged (REQUIRED) that the
new `Mdr.STMVar` arm added to `genericMemberSigToMsil` for Gap 2
(`emitGenericMethodExternCall`, D-progress-929) has a side effect on Gap 1's
own function, `emitGenericExternMember`: a member that is BOTH on a
generic-declaring type AND has its own method-level generic parameter —
e.g. `System.Collections.Generic.List<T>.ConvertAll<TOutput>(Converter<T,
TOutput>): List<TOutput>` — now has its signature CONVERTED successfully
(`convOk = true`) by `genericMemberSigToMsil`, where before the `STMVar` arm
existed the method's own MVAR position (`TOutput`, inside the
`Converter<T,TOutput>` parameter and the `List<TOutput>` return) had no
`Mdr.SigType` arm and correctly declined (`convOk = false`, falling through
to a build-time "extern member could not be resolved" diagnostic).

**Reachability.** Reachable with a real, unremarkable BCL API — no gRPC
package or exotic type needed. Reproduced directly: a Lyric wrapper
`func listOfConvertAll[T, TOutput](l: in ListOf[T], converter: in (T) ->
TOutput): ListOf[TOutput] = ()` around `List<T>.ConvertAll<TOutput>`
compiles CLEAN (no build error) on the pre-fix compiler, but faults at CLR
load time:

```
Unhandled exception. System.BadImageFormatException: An attempt was made to
load a program with an incorrect format.
   at ListConvertAllFixture.Program.listOfConvertAll__Int__String(Object, Func`2)
```

Root cause: `emitGenericExternMember` builds a closed GENERICINST TypeSpec
for the declaring type (`List<Int>`) and emits a plain
`call`/`callvirt`/`newobj` against a MemberRef parented on that TypeSpec —
correct for `ConvertAll`'s DECLARING-type VAR (`!0`), but the method's OWN
generic parameter (`TOutput`, `!!0`) is never instantiated via a MethodSpec
(ECMA-335 §II.23.2.29 requires one whenever a called method's own
signature still contains an unresolved `!!n`). The MemberRef signature
correctly ENCODES `!!0` (thanks to the `STMVar` arm), but nothing ever
instantiates it before the call — invalid IL that compiles clean and only
faults when the CLR loader tries to JIT the method body.

`emitGenericMethodExternCall` (Gap 2, D-progress-929) implements exactly
the missing MethodSpec-witnessing machinery, but only for a
NON-generic-declaring type (`genericArityOfName(r.typeName) <= 0`,
i.e. `Enumerable`/`Array`-shaped calls); `emitGenericExternMember` is a
structurally different function (it builds the declaring-type TypeSpec
Gap 2's function never needs) and has no equivalent path.

**Fix.** Added a `sig.isGeneric` check in `emitGenericExternMember`,
immediately after the existing `isValType and isInstance` panic (D-progress-686
/ #5809) and before any TypeSpec/MemberRef emission: when the resolved BCL
signature is itself a generic method (`sig.isGeneric`), panic loudly rather
than proceeding to emit invalid IL — mirroring the `isValType and
isInstance` precedent immediately above it and the `#5809`/`#6995` family of
declined-rather-than-silently-broken shapes this same PR already
established. Implementing the actual combined TypeSpec-parent +
MethodSpec-witnessed call is a materially larger change (needs both the
declaring-type instantiation this function already builds AND Gap 2's
MethodSpec witnessing, correctly composed) and is out of scope for a
review-response fix; tracked as a follow-up under #7138.

**Verification.** Reproduced the pre-fix `BadImageFormatException` against
a standalone repro (`List<T>.ConvertAll<TOutput>` via a
`(T) -> TOutput`-typed Lyric wrapper parameter, matched to `Converter<T,
TOutput>` through the existing TFunction-to-delegate FFI ABI, docs/50/52) —
confirmed reaching `sig.isGeneric = true, genParamCount = 1, convOk = true`
before the fix, via a temporary debug instrumentation pass (removed before
landing). New test "generic-declaring-type member with its own
method-level generic fails the build cleanly, not with a load-time
BadImageFormatException (#7138)" added to
`generic_extern_valuetype_instance_self_test.l` (the established
`Lyric.Emitter`-based harness for this class of build-time-decline test,
alongside the existing value-type-instance and async-generic-method
declines) — asserts the refusal is contained (no thrown `Bug`, no output
artifact) and names the unsupported shape. `generic_extern_valuetype_instance_self_test.l`:
3/3 pass (was 2/2).

**Related:** #6581/D-progress-929 (Gap 1, the function this entry adds a
guard to), D-progress-930 (`#6989`, the `Mdr.STMVar` arm this entry's
newly-reachable shape depends on), D-progress-937 (#7137, the review
finding that led to discovering this one — both surfaced in the same
review pass), #5809 (the `isValType and isInstance` precedent this entry's
guard placement mirrors), #7138 (this review finding; the full
combined-TypeSpec-plus-MethodSpec implementation remains open there), PR
#6981.
