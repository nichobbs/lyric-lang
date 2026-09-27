# `clrIsValueType` SDK-less fallback: 11 missing entries fixed (#7488, D-progress-1003)

`Msil.Ffi.clrIsValueType` (the SDK-less fallback list `argFqnToMsil`,
`externValueTypeMsil`, and `externTargetBracketGenericInstMsil` consult when
no .NET reference-assembly pack is on disk) had drifted out of sync with the
value-typed `extern type` declarations under `lyric-stdlib/std/_kernel/`.
11 real BCL value types — `System.Double`, `System.Char`,
`System.StringComparison`, `System.Net.Sockets.AddressFamily` /
`SocketType` / `ProtocolType`, `System.Net.Http.HttpVersionPolicy`,
`System.Net.Security.SslPolicyErrors`,
`System.Security.Authentication.SslProtocols`, and
`System.Security.Cryptography.X509Certificates.X509ChainTrustMode` /
`X509RevocationMode` — were missing from both `clrIsValueType` and its
`expectedClrValueTypes()` mirror in
`lyric-stdlib/tests/metadata_reader_tests.l`'s `testClrValueTypeAudit`,
meaning an SDK-less build would silently mistag them as reference types
(CLASS instead of VALUETYPE) in a GENERICINST or MemberRef signature.

Found via a one-off diagnostic variant of `testClrValueTypeAudit` that
reports every drift in a single run instead of panicking at the first one
(not committed — `testClrValueTypeAudit` itself is unchanged in structure).
All 11 added to both lists together, per the test's own instructions.
Verified clean re-run with zero drift remaining against the real
reference-assembly pack.

See `docs/decisions/D-progress-1003-clr-value-type-audit-drift-fix.md` for
the full list and rationale. This audit test is still not wired into CI
(pre-existing gap, tracked separately) — this fix closes the drift it
exists to catch, not the CI-wiring gap itself.
