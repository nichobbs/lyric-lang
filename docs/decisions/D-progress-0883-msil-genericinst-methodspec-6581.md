# D-progress-883 — MSIL codegen: GENERICINST-shaped member params/returns on a generic-declaring type, and MethodSpec for a BCL method with its own generics, both now emit correctly (#6581)

**Status:** shipped

**Context.** `docs/42-extern-metadata-resolution.md`'s Phase 4 verified a
declared `@externTarget` signature against reference-assembly metadata but
explicitly deferred full MethodSpec routing for generics — "the verification
block skips params whose `MsilType` has no `SigType` equivalent." Two concrete
gaps fell out of that deferral, both confirmed (independently, against the
real 2.65.0 reference-assembly metadata) to block `lyric-grpc`'s entire
unary/streaming/server-hosting surface (D-progress-877, #6592, #5409):

- **Gap 1 — GENERICINST member parameter/return.** A generic-declaring-type
  member whose own parameter or return is itself a *closed generic
  instantiation over the declaring type's VAR* — `List`1..ctor
  (IEnumerable`1<!0> source)`, `Marshaller`1..ctor(Func`2<!0,uint8[]>
  serializer)`, `Marshallers.Create<T>`'s `Func<DeserializationContext,T>`
  parameter — had no `Mdr.SigType` arm in `genericMemberSigToMsil`
  (`lyric-compiler/msil/codegen.l`) at all: the whole signature was silently
  discarded and the caller fell back to a MemberRef parented on the OPEN
  generic-declaring TypeRef — an ECMA-335 §II.22.25 violation (a MemberRef's
  parent must be a closed TypeSpec when the declaring type is generic) that
  the CLR loader faults with `TypeLoadException` the moment the member is
  invoked.
- **Gap 2 — MethodSpec for a BCL method with its own generics.** A BCL method
  declared with method-level generics on a *non*-generic-declaring type
  (`CallInvoker.BlockingUnaryCall<TRequest,TResponse>`,
  `ServiceBinderBase.AddMethod<TRequest,TResponse>`) falls outside
  `emitGenericExternMember`'s `genericArityOfName` gate (specific to a
  generic-declaring TYPE's own arity) and had no MethodSpec (table 0x2B)
  emission path for a user `@externTarget` call: ECMA-335 §II.23.2.29
  requires instantiating a generic method's own parameters via a MethodSpec
  at the call site, and no such emission existed outside the compiler's two
  internal async-state-machine call sites (`ctxAddMethodSpec`'s only prior
  callers).

**Fix.**

- **Gap 1.** Added an `Mdr.STNamedGenericInst` arm to `genericMemberSigToMsil`
  that recurses into the instantiation's own type arguments via
  `genericMemberSigToMsil` (not `resolvedSigToMsil`), so a nested `!0`/`!!0`
  is preserved rather than discarded, producing `MGenericInst`/
  `MValueTypeGenericInst`. Preserving the signature shape was not sufficient
  by itself: the Lyric argument at such a position is statically only
  `object` (every generic-function slot's erasure convention), while the
  TypeSpec-substituted parameter type is a REAL closed type (e.g.
  `IEnumerable`1<object>` under the `<object,…>` erasure default) — the CLR
  verifier rejects the bare `object` there. `substituteDeclaringVarMsil`
  substitutes the enclosing TypeSpec's own instantiation args into a member
  signature's VAR positions (mirroring the CLR's own MemberRef-through-
  TypeSpec substitution), and `emitGenericExternMember`'s argument-loading
  loop emits a `castclass` to the substituted type before the call.
  `argTyToSig` gained arms for Lyric's own `List[T]`/`Map[K,V]`/
  `MConcreteList`/`MConcreteMap` (describing them by their base generic-arity
  FQN, e.g. `System.Collections.Generic.List`1`), and `scoreSigType` gained an
  `STNamedGenericInst` parameter arm (scored 0, weak-but-nonnegative — the
  same precedent the pre-existing bare `STVar` arm already sets for
  "accepts any argument once the type is closed over a concrete
  instantiation") — both needed so the SCORED resolver
  (`resolveExternMethodScoredIn`) can disambiguate a same-arity overload set
  where only one candidate takes a generic-instantiation-shaped parameter
  (e.g. `List`1..ctor(IEnumerable`1<!0>)` vs the nullary `.ctor()`) instead
  of every candidate scoring -1 and falling back to the unscored,
  first-in-Method-table arity-only resolver.
- **`.ctor`-arity scoring bug, found while landing Gap 1.**
  `resolveExternMethodScoredIn`'s `hasThis`-derived branch selection did not
  gate its ctor-specific branches on `member == ".ctor"`: a ctor candidate
  whose own arity did NOT equal `declArity` (e.g. a nullary `List`1..ctor()`
  when the caller supplies 1 argument) fell through to the
  `isInstance and nReal == declArity - 1` branch — written for genuine
  instance METHODS, where dropping `fullArgTypes[0]` as an implicit receiver
  is correct, but a ctor's `hasThis` bit (always set per ECMA-335
  §II.15.4.1.5) has no such implicit receiver in `fullArgTypes` at all. With
  `declArity == 1`, `tail` (`fullArgTypes[1..]`) was accidentally EMPTY and
  scored a spurious exact match (`+exactBonus`) against the ALSO-empty
  nullary ctor's own param list — silently outscoring, or tying and then
  winning by Method-table row order, the correct overload whenever one
  existed. This was a **silent-miscompile risk that predates this PR**,
  latent until Gap 1 gave the resolver a real reason to hit a same-arity
  ctor overload set for the first time (`List`1..ctor(IEnumerable`1<!0>)` vs
  `.ctor()`). Fixed by wrapping every ctor-specific branch (the exact-arity
  and trailing-optional-prefix cases) inside its own `member == ".ctor"`
  block, ahead of and independent from the `isInstance`-branch chain, so a
  ctor whose own arity does not match `declArity` and has no admissible
  trailing-optional path scores `-1` outright rather than falling into
  instance-method scoring.
- **Gap 2.** `buildOpenGenericMethodSigCtx` builds the ECMA-335 §II.23.2.1
  GenericMethodSig blob (`HASTHIS? | GENERIC(0x10)`, generic-param count,
  then the ordinary param-count/return/params) for an OPEN generic-method
  MemberRef. `resolvedSigToMsil` and `genericMemberSigToMsil` both gained an
  `Mdr.STMVar` arm mapping to a new `MMethodTypeVar(index)` `MsilType` case
  (`lyric-compiler/msil/lowering.l`; distinct from the pre-existing
  `MTypeVar` for a declaring TYPE's own VAR, encoding `!!n`/
  `ELEMENT_TYPE_MVAR = 0x1E` instead of `!n`/`ELEMENT_TYPE_VAR = 0x13`), so
  `buildOpenGenericMethodSigCtx` can preserve the method's own generic
  positions rather than falling back to the (already object-erased) Lyric-
  declared argument type there. `emitGenericMethodExternCall` builds this
  open MemberRef, then a MethodSpec witnessing every one of the method's own
  generic parameters with `System.Object` — the same object-erasure
  convention `emitGenericExternMember` already applies to an unbracketed
  generic-declaring-TYPE instantiation. This is exact for any generic
  parameter whose only constraint is `class` (the common case for
  message/DTO-shaped generic methods — `TRequest`/`TResponse` in gRPC's
  `CallInvoker`/`ServiceBinderBase`), but would fail CLR class-load for a
  witness needing to satisfy an interface/base-class constraint `object`
  doesn't meet; no such case is known in the ecosystem this ships for.
  Value-type receivers decline (fall back to the pre-existing best-effort
  path, matching #5809's existing value-type-generic-member limitation)
  since the call sequence always emits `ldarg` + `callvirt`, valid only for a
  reference-type receiver. Wired into `emitExternTargetBody`'s existing
  metadata-resolved-signature branch: on `msig.isGeneric`, this path is tried
  first; on decline, `resolvedMethodParams`/`resolvedMethodRet` are left
  unset (as if metadata resolution found nothing) rather than falling into
  the plain-method path below with an `msig` shape it cannot safely consume.

**Verification.** `ilverify` was run against a standalone repro of the exact
Gap 1 shape during development, independently catching both the missing
`Mdr.STNamedGenericInst` signature arm (whole signature silently discarded)
and, once that was added, the missing `castclass` (verifier rejected the
bare-`object` argument against the substituted closed parameter type) as two
separate failures before both were fixed. New self-test
`generic_extern_methodspec_self_test.l` (2 cases, BCL-only shapes so CI needs
no `lyric-grpc`/gRPC NuGet package): `System.Collections.Generic.List`1`'s
`IEnumerable<T>`-parameter ctor (Gap 1: constructs a 3-element `List<string>`
from a `slice[String]`, asserts the count) and
`System.Linq.Enumerable.Empty<TResult>()` (Gap 2: a generic method on a
non-generic-declaring type; two calls compared via `Object.ReferenceEquals`
prove the MethodSpec-instantiated call reached the real per-`T` cached
singleton the BCL guarantees, ruling out both a load-time fault and a
mis-instantiated call landing on the wrong per-`T` instance). Full regression
sweep with zero failures: `generic_extern_self_test.l` (7/7),
`generic_extern_valuetype_instance_self_test.l` (1/1 — the existing
value-type-receiver decline path unaffected), `nested_generic_self_test.l`
(8/8), `mono_self_test.l` (82/82), `cross_package_generics_self_test.l`
(10/10), `msil_restored_bridge_self_test.l` (6/6), `msil_project_bridge_self_test.l`
(53/53), `auto_ffi_self_test.l` (pre-existing failure on this container,
confirmed via `git stash` to reproduce identically against unmodified
`origin/main` — an environment-specific reference-assembly-pack difference,
not a regression from this change).

**Scope note.** A test exercising a generic `@externTarget` function's own
TFunction-typed parameter whose delegate argument is a lambda inferred with a
concrete (non-erased) type at the call site (`ConcurrentDictionary.GetOrAdd`
with a `(K) -> V` factory) was drafted alongside this fix and found to
surface a genuine, SEPARATE bug: the strongly-typed lambda ABI (docs/50/52)
constructs the call-site delegate using the call site's own concretely-
inferred argument type (e.g. `Func<string,object>`), while the generic
`@externTarget` wrapper's own erasure convention expects `Func<object,object>`
at that position — a real CLR delegate-variance conflict (`Func<in T, ...>`
is contravariant in `T`, so a `Func<string,object>` instance cannot cast to
`Func<object,object>`) that no `castclass` can bridge. Confirmed via the same
`git stash` technique that this reproduces identically with Gap 1's
`castclass` logic disabled, ruling out this PR as the cause. Pulled out of
this PR's test file to keep it focused; tracked for its own fix under #5800.

**Related:** #6581 (fixed by this PR), D-progress-877 (the independent
re-verification that this PR's fix is exactly what unblocks server hosting
too, not just unary/streaming), #6592/#5409 (`lyric-grpc`'s tracking issues,
still blocked on `lyric-grpc`'s own remaining work even after this fix lands
— this PR is compiler-only), #5800 (the newly-surfaced delegate-erasure
scope-note bug, tracked separately), #5809 (the pre-existing value-type-
generic-member limitation this fix does not touch),
`docs/42-extern-metadata-resolution.md` §5 Phase 6 (this fix's design write-up).
