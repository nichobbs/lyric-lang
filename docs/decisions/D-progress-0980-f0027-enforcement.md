# D-progress-980 — F0027 promoted from warning to build-gating error (#5704 enforcement)

**Status:** shipped (partial — see "Still open")

**Context.** D-progress-945 (#7169) audited every `lyric-*/` package plus
`lyric-stdlib` for the `F0027` hint-less-`@externTarget` warning and found
(and fixed) the only two remaining root-cause patterns ecosystem-wide,
confirming zero `F0027` warnings across the whole known tree. That was the
explicit prerequisite #5704's own "why deferred" section named before F0027
could safely gate a build: "a full ecosystem audit... must precede enabling
F0027."

**This entry ships the enforcement half.** `emitExternTargetBody`
(`lyric-compiler/msil/codegen.l`) previously called
`warnHintlessExternUnverifiedMsil`, a bare `Console.error` print outside the
diagnostics pipeline, whenever a hint-less (`RHEither`) `@externTarget`
instance method's calling convention could not be confirmed against
reference-assembly metadata. That call site now instead appends an
`errorDiagnostic("F0027", …, decl.span)` to `cctx.diagnostics` — the same
convention `F0015` already uses for the sibling "declared signature doesn't
match any real overload" hazard — so `Msil.Bridge`'s post-codegen
`diagReportAndAbort` check aborts the build instead of silently emitting a
static-call guess that would fault at runtime with
`MissingMethodException` if the member is actually an instance method.

The gating condition is **unchanged** from the warning it replaces: fires
only when (a) the extern is hint-less, (b) it is not a constructor
(ctors always use `newobj` regardless of hint), (c) neither the
property-getter probe nor metadata-scored method resolution could confirm
the calling convention, and (d) the declaring type IS present in the
reference-assembly index — which includes types from a **restored NuGet
package**, not just the BCL: `ensureMetadataIndex`'s Phase 5 feeds every
restored NuGet assembly's metadata into the same `cctx.metadataTypeIndex`
this gate checks.

**D-progress-945's audit had a blind spot this PR found and closed.**
D-progress-945 grepped the ecosystem for exactly two BCL-only patterns
(`Monitor.Enter`/`Exit`, `BitConverter.SingleToInt32Bits`) and, on that
basis, claimed "zero remaining occurrences" across every `lyric-*/`
package. It never exercised a NuGet-backed extern kernel as its own
category. Turning this enforcement on for real surfaced exactly that gap:
`lyric-session/src/_kernel/net/session_kernel.l` had three hint-less
`@externTarget`s over `StackExchange.Redis.IDatabase` (`strSetCreate`,
`strSetKeepTtl`, `keyExpire`) that D-progress-945 never found, because a
grep for `Monitor`/`BitConverter` was never going to match `IDatabase`.
Fixed here with the same `@externInstance` hint the D-progress-945
pattern used (see the commit adding it to `session_kernel.l` for the
verification: `lyric restore` + `lyric test --features dotnet` against a
live Redis server, 6/6 test files green). This means the promotion is
**not** exactly behavior-preserving relative to D-progress-945's own
audited set — it needed this additional, undisclosed-until-now fix to
stay green.

**Extending the sweep to the NuGet-backed category specifically.** Every
`lyric-*/` package with a real `[nuget]` dependency (`lyric-aws-secrets`,
`lyric-aws-xray`, `lyric-db`, `lyric-grpc`, `lyric-jobs`, `lyric-mail`,
`lyric-mq`, `lyric-session`; `lyric-docker`/`lyric-web` declare empty
`[nuget]` tables with BCL-only comments, not real dependencies) was
restored and built with its NuGet-activating feature(s) enabled:

- Clean, zero `F0027`: `lyric-aws-secrets` (`--features aws`),
  `lyric-aws-xray` (`--features aws`), `lyric-db` (default features,
  Npgsql + Microsoft.Data.Sqlite both active), `lyric-grpc` (default
  `dotnet` feature, `Grpc.Net.Client`), `lyric-session` (`--features
  dotnet`, `StackExchange.Redis`, after the fix above).
- **Not evaluable for F0027 at all**: `lyric-jobs --features
  dotnet,inprocess,hangfire`, `lyric-mail --features smtp`, `lyric-mq
  --features dotnet,rabbitmq` each fail to build for reasons unrelated to
  F0027 and pre-dating this PR (a duplicate top-level `connect` between
  the `inprocess`/`hangfire` kernels in `jobs_kernel.l`; unreachable
  `Some`/`None` patterns in `mail.l`; unresolved `Mq.Kernel.Net.*` names
  in `mq.l`) — confirmed by grepping each failure's output for `F0027`
  (none present) and by CLAUDE.md's own README notes that Hangfire and
  most non-default MQ backends are `NOT_IMPLEMENTED` stubs on `dotnet`
  today. Since these packages do not build in these configurations
  regardless of this PR, F0027 enforcement cannot be the thing that newly
  breaks them; whether they build at all is pre-existing, tracked
  elsewhere, and out of scope here.

So the accurate claim is: this promotion is verified clean against every
NuGet-dependent package that **currently builds** in its
production-feature configuration (the D-progress-945 BCL-pattern set plus
the NuGet-backed set enumerated above), not merely "every tree
D-progress-945 already covered" as an earlier draft of this entry
overstated.

**Tests added** (`lyric-compiler/lyric/msil_codegen_diag_self_test.l`,
extending its existing F0021–F0026 diagnostic-conversion pattern):

- Negative: a hint-less `@externTarget` over a real BCL instance method
  (`System.Text.StringBuilder.Append`) declared with a deliberately
  mismatched arity, so the metadata scorer finds no matching overload and
  the calling convention stays unconfirmed — asserts **F0027** fires at
  the extern function's declaration span, not a runtime
  `MissingMethodException`.
- Positive control: the same shape but with the CORRECT arity (a
  metadata-verifiable hint-less instance extern) still compiles cleanly —
  pins that the promotion doesn't turn a legitimate verified-hint-less
  call into a false positive.

**Still open.** `lyric-jobs`'s hangfire feature, `lyric-mail`'s smtp
feature, and `lyric-mq`'s rabbitmq feature are pre-existing broken build
configurations (see above) that this entry did not fix — they are
unrelated to F0027 and out of scope for this PR. This does **not** cover
the SDK-less build path (the
reference-assembly index entirely absent, `Mdr.assemblyForType` returning
`None` for every type) — today that path still compiles a hint-less
instance extern silently with no diagnostic at all. #5704's own test list
asked for an "SDK-less harness (ref pack hidden)" case; no such harness
exists in the test suite today (`metadata_reader_self_test.l` only asserts
whatever `refPackDir()` naturally finds on the host, never forces an empty
index), and building one plus deciding how to tell "legitimately
non-BCL host type" apart from "SDK-less build" in that branch is real,
separately-scoped work. Filed as #7387 rather than attempted here, per the
"smaller slice done properly" standard.

**Related:** #5704 (enforcement half shipped; SDK-less half tracked in
#7387), D-progress-945/#7169 (the audit prerequisite), D-progress-671 (the
original F0027 warning), F0015 (`msil/codegen.l`, the sibling diagnostic
this mirrors).
