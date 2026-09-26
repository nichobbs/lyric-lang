# D-progress-979 — F0027 promoted from warning to build-gating error (#5704 enforcement)

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
reference-assembly index. Condition (d) means this promotion is exactly
behavior-preserving for every build the D-progress-945 audit already
verified clean — no new build breaks for any tree already exercised by
that audit, only a change to what a *new* violation does (fail the build
instead of printing a warning nobody is required to act on).

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

**Still open.** This does **not** cover the SDK-less build path (the
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
