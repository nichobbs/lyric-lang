# D-progress-1003 — Fix pre-existing `clrIsValueType` / `expectedClrValueTypes()` drift (#7488)

**Status:** shipped

## Context

`Msil.Ffi.clrIsValueType` (`lyric-compiler/msil/ffi.l`) is the SDK-less
fallback list `codegen.l`'s `externValueTypeMsil`, `argFqnToMsil`, and
`externTargetBracketGenericInstMsil` consult to tag a bracket-suffixed or
GENERICINST-argument extern type as VALUETYPE instead of CLASS when no .NET
reference-assembly pack is on disk to consult the real metadata. Its own doc
comment says it "must stay in lockstep with the value-typed `extern type`
declarations in `lyric-stdlib/std/_kernel/*.l`" and that drift "mis-encodes
as CLASS in SDK-less builds and faults at run time with
`MissingMethodException`."

`lyric-stdlib/tests/metadata_reader_tests.l`'s `testClrValueTypeAudit`
enforces this lockstep by scanning every `extern type X = "FQN"` declaration
under `_kernel/` and comparing, per FQN, the real reference-assembly metadata
(`isValueTypeFqn`) against the hardcoded `expectedClrValueTypes()` mirror of
`clrIsValueType`. This test is **not wired into any CI step** (see the file's
own header — it needs `LYRIC_LOAD_COMPILER=1` to resolve its
`Msil.MetadataReader` import, and a separate pre-existing gap,
`testTableRows`'s Param-row sequence assertions, #5624, blocks running the
whole file's `main()` end to end), so this drift accumulated silently over
time as new enum/primitive-wrapping `extern type` declarations were added to
`_kernel/*.l` without a matching `clrIsValueType`/`expectedClrValueTypes()`
update.

Discovered while validating #7449 (D-progress-999)'s own
`clrIsValueType` addition (`System.Net.Security.SslApplicationProtocol`) via
an isolated copy of `testClrValueTypeAudit` — the audit panics at the first
mismatch it finds, so only one or two drifted entries were visible per run;
filed as #7488 to fix comprehensively rather than folding an open-ended
audit into that PR.

## Decision

Built a temporary diagnostic variant of `testClrValueTypeAudit` (not
committed — a scratch copy with the `panic` calls replaced by `println` so
every mismatch is reported in one run instead of stopping at the first) to
enumerate the complete drift set in one pass. Found 11 missing entries, all
in the same direction (a real BCL value type, declared as an `extern type`
somewhere under `_kernel/`, absent from both `clrIsValueType` and
`expectedClrValueTypes()`):

- `System.Double`, `System.Char` — primitive value types, aliased for the FFI
  boundary (`_kernel/math_host.l`'s `NetDouble`, `_kernel/char_host.l` /
  `_kernel/encoding_host.l` / `_kernel/unicode_host.l`'s `NetChar` /
  `UnicodeChar`).
- `System.StringComparison` (`_kernel/string_host.l`).
- `System.Net.Sockets.AddressFamily`, `System.Net.Sockets.SocketType`,
  `System.Net.Sockets.ProtocolType`, `System.Net.Http.HttpVersionPolicy`
  (`_kernel/http_host.l`).
- `System.Net.Security.SslPolicyErrors`,
  `System.Security.Authentication.SslProtocols`,
  `System.Security.Cryptography.X509Certificates.X509ChainTrustMode`,
  `System.Security.Cryptography.X509Certificates.X509RevocationMode`
  (declared in both `_kernel/http_host.l` and `_kernel/tcp_host.l`; the
  scanner dedupes by FQN so the double declaration doesn't double-count).

Added all 11 to `Msil.Ffi.clrIsValueType` and to `expectedClrValueTypes()`
together, per the audit's own instructions. No `clrIsValueType` entries were
stale in the other direction (a listed entry that's no longer a real value
type or no longer declared) — all drift was one-directional (missing, not
spurious).

## Verification

Re-ran the same panic-to-println diagnostic variant after the fix: zero
drift lines emitted across all `_kernel/*.l` externs (confirmed against a
real .NET reference-assembly pack). The diagnostic variant itself is
throwaway tooling, not committed — `testClrValueTypeAudit` in
`lyric-stdlib/tests/metadata_reader_tests.l` is unchanged in structure, only
its `expectedClrValueTypes()` data is extended.

This fix does not change any codegen behavior with a reference pack present
(the metadata-derived `vtypeSet` was always authoritative there); it only
changes what an SDK-less build falls back to for these 11 FQNs, which
previously silently mistagged as CLASS.
