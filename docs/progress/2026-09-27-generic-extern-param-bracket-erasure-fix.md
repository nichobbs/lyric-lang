# Generic-collection-over-extern-value-type parameters/returns now bind at `@externTarget` FFI boundary (#6029, D-progress-998)

A bracket-suffixed extern-type alias (a closed generic instantiation such as
`List\`1[SomeValueType]`) used as a **parameter or return type** of an
`@externTarget` member now resolves to its real `GENERICINST` signature
instead of being erased to `System.Object`. Previously this erasure was only
recovered when the alias was the *receiver* of its own generic-declaring-type
member call (`emitGenericExternMember`); every other position silently lost
the type, so a real BCL API like `SslServerAuthenticationOptions.
set_ApplicationProtocols(List<SslApplicationProtocol>)` compiled clean but
threw `MissingMethodException` at run time.

Also fixed: `argFqnToMsil` (used to encode a bracket suffix's own
type-argument FQNs into a TypeSpec) unconditionally tagged non-primitive
arguments as reference types — wrong for a value-type argument, which needs
its own VALUETYPE tag per ECMA-335 §II.23.2.12.

Scope: this fixes the explicit `@externTarget`-wrapper path only (including a
constructor whose own `@externTarget` string carries no bracket suffix,
inferring the real instantiation from the declared return-type alias). The
auto-FFI *direct* property-assignment sugar (`opts.ApplicationProtocols =
list`, no `@externTarget` wrapper) is unaffected — that path needs
`argTyToSig`/`scoreSigType` extended to describe and structurally match a
closed generic instantiation, filed as a separate follow-up. See
`docs/66-ffi-generic-instantiation-boundary.md` for the full scoping of this
gap and three related, still-open ones (delegate-erasure contravariance,
`ByRefLike` types, and Lyric's own `List[T]`/`Map[K,V]` local-hint
threading), and `docs/decisions/D-progress-0998-generic-extern-param-return-
bracket-erasure.md` for the shipped decision.

New self-test: `lyric-compiler/lyric/generic_extern_param_self_test.l`,
mirroring #6029's own repro against the real BCL API. No F# changes; MSIL
backend only (`lyric-compiler/msil/codegen.l`).

Follow-up fixes from review: both `argFqnToMsil` and
`externTargetBracketGenericInstMsil` now fall back to the hardcoded
`Msil.Ffi.clrIsValueType` closed set (extended with
`System.Net.Security.SslApplicationProtocol`) when no reference pack is on
disk, matching `externValueTypeMsil`'s existing SDK-less fallback. And
`_kernel/tcp_host.l`'s `setApplicationProtocols` — a reflection-based
workaround for this exact BCL signature that #6029 itself said to retire once
the emitter could encode it — is migrated to a direct
`@externTarget`-wrapped `List<SslApplicationProtocol>` construction, removing
the `Type`/`Activator`/`IList`/`PropertyInfo` reflection bridge entirely.
Verified against the real end-to-end ALPN/TLS suites (`tcp_host_tls_tests.l`,
`http_server_dotnet_tests.l`, `dotnet_h2_smoke.l`).
