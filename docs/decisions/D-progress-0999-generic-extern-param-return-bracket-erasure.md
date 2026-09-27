# D-progress-999 — Recover closed generic instantiation at an `@externTarget` parameter/return position instead of erasing to `object` (#6029)

**Status:** shipped

## Context

`Msil.Codegen.typeExprToMsilCtx`'s `TRef` branch erases any bracket-suffixed
extern-type alias (`extern type ProtoList = "System.Collections.Generic.
List\`1[System.Net.Security.SslApplicationProtocol]"` — a closed generic
instantiation) straight to `MObject`. The justifying comment says member
calls on it route through `emitGenericExternMember`, which is true only when
the alias is the **receiver** of its own generic-declaring-type member call.
`SslServerAuthenticationOptions.set_ApplicationProtocols(List<
SslApplicationProtocol>)` takes the alias as a **parameter** of an unrelated,
non-generic-declaring method — `emitGenericExternMember` never runs for that
call (its dispatch is gated on the call target's own declaring-type name, not
on any parameter type), so the erased `MObject` flowed straight into the
`@externTarget` MemberRef signature and the call could never bind
(`MissingMethodException` at run time, confirmed against the real BCL API by
three independent investigating sessions before this one, tracked as #6029).

A second, independent bug compounded it: `argFqnToMsil` (used to convert a
bracket suffix's own type-argument FQNs to `MsilType` for TypeSpec
construction) unconditionally tagged any non-primitive argument as
`MClassRef` — wrong for a value-type argument (`SslApplicationProtocol` is a
struct). ECMA-335 §II.23.2.12 requires a GENERICINST type argument's own
CLASS/VALUETYPE tag to match its real CLR kind; the wrong tag loads with
`TypeLoadException` even once the erasure bug above is fixed.

## Decision

Ship the smallest of the four independently-scoped gaps this investigation
found (see `docs/66-ffi-generic-instantiation-boundary.md` for the full
scoping of all four and the three that remain unshipped) at production
quality:

1. Fix `argFqnToMsil` to check `Mdr.isValueTypeFqn` and return
   `MValueTypeRef` for a struct argument instead of unconditionally
   `MClassRef`.
2. Add `externTargetBracketGenericInstMsil`, a narrowly-scoped helper that
   recovers the real `MGenericInst`/`MValueTypeGenericInst` for a
   bracket-suffixed extern-type alias used as an `@externTarget`
   parameter or return type — reusing the exact `stripBracketSuffix` /
   `parseBracketArgFqns` / `argFqnToMsil` / `internFfiTypeRefNested`
   building blocks `emitGenericExternMember` already uses for the
   receiver-position case. Wired into `emitExternTargetBody`'s
   parameter-type loop and return-type computation as an extra match arm,
   scoped to `@externTarget` signatures only (mirroring the existing
   `TFunction` special case's scope, D122) — the general erasure
   convention every other `typeExprToMsilCtx` caller depends on (locals,
   fields, non-`@externTarget` functions, generic-declaring-type
   receivers) is untouched.

As a side effect this also closes what #6029 called "Gap C" for free:
`emitGenericExternMember`'s existing `r.isCtor` branch already had a
mechanism (`retArgs`) to infer a ctor's real type arguments from a matching
`MGenericInst`/`MValueTypeGenericInst` **return** type — it simply never
received one, since the return type was always the `MObject` erasure before
this fix. No new construction-side code was needed for a ctor whose own
`@externTarget` string carries no bracket suffix (`newList()` inferring
`List<SslApplicationProtocol>` purely from its declared `ProtoList` return
type — the exact shape #6029 originally reported).

## Follow-up: SDK-less fallback and stdlib migration (review round 2)

Two REQUIRED findings from `claude-review`'s second pass:

1. `argFqnToMsil` and `externTargetBracketGenericInstMsil` consulted only the
   metadata-derived `cctx.metadataVtypeSet` to decide VALUETYPE vs. CLASS —
   correct with a reference pack on disk, but silently wrong in an SDK-less
   build (an empty vtypeSet), reproducing the exact mistagging bug this fix
   exists to prevent. Fixed by falling back to the same hardcoded
   `Msil.Ffi.clrIsValueType` closed set `externValueTypeMsil` already
   consults for the identical reason, and added
   `System.Net.Security.SslApplicationProtocol` to that list (and its
   `expectedClrValueTypes()` mirror in `metadata_reader_tests.l`) since it is
   now the first value-typed GENERICINST *argument* the fallback needs to
   cover, not just a bare parameter/return/field type.
2. `_kernel/tcp_host.l`'s `setApplicationProtocols` used a reflection-based
   workaround for exactly this fix's target shape
   (`SslServerAuthenticationOptions.set_ApplicationProtocols(List<
   SslApplicationProtocol>)`), and #6029's own body said to remove it once
   the emitter could encode the real signature. Migrated it to a direct
   `@externTarget`-wrapped `List<SslApplicationProtocol>` construction +
   setter (mirroring this PR's own self-test), deleting the ~90 lines of
   `Type`/`Activator`/`IList`/`PropertyInfo` reflection plumbing that existed
   only for this one call site. Verified end-to-end against the real ALPN
   negotiation path (`tcp_host_tls_tests.l`, `http_server_dotnet_tests.l`,
   `dotnet_h2_smoke.l` — all three exercise a real TLS handshake / HTTP-2
   `curl` round trip, not just a compile check).

One SUGGESTION not acted on: `externTargetBracketGenericInstMsil` requires a
bare single-segment `TRef` (`path.segments.count == 1`), so a bracket-suffixed
alias reached through a qualified/cross-package path still falls back to the
`MObject` erasure rather than this fix's recovery — narrower than
`typeExprToMsilCtx`'s own `externTypeNames` lookup, which resolves via
`lastSegmentMsil(path)` regardless of segment count. No known real-world
`@externTarget` signature hits this today (every existing kernel/ecosystem
consumer, `tcp_host.l`'s new migration included, uses a bare unqualified
alias name), so it is left as a documented gap rather than widened
speculatively.

Validating the `clrIsValueType`/`expectedClrValueTypes()` addition against the
manual (not CI-wired) `testClrValueTypeAudit` in `metadata_reader_tests.l`
confirmed `SslApplicationProtocol` itself introduces no drift, but surfaced
pre-existing, unrelated drift for other `_kernel/` enum externs
(`SslProtocols`, `X509ChainTrustMode`) that predates this PR — filed as #7488
rather than folded in here.

## Scope explicitly not covered

The auto-FFI **direct** property-assignment sugar (`opts.
ApplicationProtocols = list`, no `@externTarget` wrapper) still panics
(`panicExternSetterUnresolved`): it resolves the setter via
`Mdr.resolveExtern`, which needs `argTyToSig` to describe an `MGenericInst`/
`MValueTypeGenericInst` value as a `SigType` (no arm exists today — only
Lyric's own `List[T]`/`Map[K,V]` are special-cased, by their base arity name,
discarding the instantiation's own type argument), and `Mdr.scoreSigType`'s
`STNamedGenericInst` arm deliberately rejects (`-1`) any **closed**
instantiation today, pending a genuine structural-match arm (a blanket-accept
there previously caused a real regression, D-progress-934). This is real,
separately-scoped follow-up work, filed as its own issue rather than folded
into this PR — a smaller, fully-finished slice beats a half-finished larger
one (CLAUDE.md's production-readiness standard).

## Follow-up: `parseBracketArgFqns` double-bracket format bug (found in CI)

Validating this fix against `lyric-aws-secrets` (`--features aws`) surfaced a
real regression: `SmClientCache`/`SsmClientCache` (`_kernel/
secrets_kernel_aws.l`) are bracket-suffixed extern-type aliases used as
`@externTarget` parameter/return types — exactly this fix's target shape —
but written in the .NET reflection "double-bracket" assembly-qualified
generic-argument form (`Type`2[[Arg1],[Arg2]]`) rather than the plain form
(`Type`2[Arg1,Arg2]`) every other existing caller of `parseBracketArgFqns`
had fed it. Before this fix's erasure recovery, that string was never
actually parsed into individual type arguments (only checked for "does it
contain `[` at all," to decide whether to erase); after, `parseBracketArgFqns`
kept the literal wrapping brackets in each extracted FQN (`"[System.String]"`
instead of `"System.String"`), interning a bogus TypeRef that faulted at
load with `TypeLoadException: Could not load type '[System.String]'`
(surfacing as a `TypeInitializationException` on the static field initializer
that first constructed one of these caches).

Confirmed via a worktree comparison against the unmodified pre-fix compiler
that this exact repro shape was never previously exercised (the erasure
convention short-circuited it), not a regression already present on `main`.

Fixed `parseBracketArgFqns` itself (not just this fix's own helper) to
normalise each comma-split argument token through a new
`normalizeGenericArgToken`: strips one layer of wrapping `[...]` and, if an
assembly-qualification suffix follows a comma inside it, keeps only the FQN
before that comma. This is a general correctness fix to already-shipped,
pre-existing parsing code (also used by `emitGenericExternMember`'s own
explicit-bracket-suffix ctor path), not scoped narrowly to the new helper.

## Verification

New self-test `lyric-compiler/lyric/generic_extern_param_self_test.l`,
mirroring #6029's own repro almost verbatim (`SslServerAuthenticationOptions`
+ `List<SslApplicationProtocol>`, ctor with no bracket suffix on its own
target string): constructs the list, sets it through the real setter, reads
it back through the real getter, and asserts the round-tripped `Count`.
Exercises both the parameter-position fix (Gap A) and the return-position
fix (Gap C) in one program. Existing FFI/generic-extern self-tests
(`auto_ffi_self_test`, `generic_extern_self_test`,
`generic_extern_methodspec_self_test`,
`generic_extern_valuetype_instance_self_test`, `typed_ffi_delegate_self_test`,
`async_extern_self_test`, `extern_enum_flags_self_test`,
`extern_option_self_test`, `ffi_iface_impl_self_test`,
`import_extern_self_test`, `typechecker_extern_dedup_self_test`) all pass
unchanged after this fix — confirmed byte-identical output for
`generic_extern_valuetype_instance_self_test`'s two expected-decline
diagnostics against the pre-fix build.
