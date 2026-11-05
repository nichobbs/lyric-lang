# D392 - Every aspect, including library templates, is woven before the check (docs/70 phase 3b slice S3, #8613)

**Status:** accepted; implemented in the same PR. Third slice of D370, after
D390 (derives) and D391 (local aspects).

## Context

D391 wove the aspects declared in the package being built before the type
check and left `from`-instances of library templates (C-mode splices,
B'-mode specialisations) to a late weave after mono, because their advice
comes from another package. The late weave kept the weaver's synthesised calls
without checker callee sites, kept `specialiseWovenContracts` (D304, M0009) and
kept a second weave path to maintain.

## Decision

1. `Weaver.weaveFileWithDiagsAndTemplates` takes `early`; with it set the weave
   resolves `from`-instances against the collected templates, builds every
   wrapper, B'-mode specialisation and record, marks the outermost wrapper
   `@__lyric_woven` (the name D391 first spelt `@woven`, now one a user does not
   write) and reports the generated runs. `pipeWeaveEarly` runs it straight
   after the derive and gives each run spans of its own (D390, D391).
2. The templates are collected from every package's file **before any is
   checked** (`MiddleEndOptions.weaveTemplates`, `weaveTypeIndex`): the MSIL
   single-file and project paths used to collect them from the post-mono files
   after the check; the JVM project path already collected from the files before
   the middle end and passes them through `pipeMiddleEnd`, which now hands them to
   `pipeCheckAndMono` in the options. A template body is therefore checked in
   the receiving package, spliced exactly as before.
3. `pipeWeave` becomes `pipeFinishWeave`: it drops the aspect declarations
   (which the checker now sees, so it checks them), lowers format builtins,
   runs `specialiseWovenContracts` and the await hoist. It no longer weaves.
   A bridge that does not pass templates gets the unresolved-`from` diagnostic,
   loudly.
3. Effects: the weave's own diagnostics (A0042-A0047 and the `from` range
   checks) are reported by the early weave and stay fatal. A woven generic
   contract call is specialised by ordinary mono, so D304's M0009 no longer
   fires for any aspect (`specialiseWovenContracts` has nothing left to do and
   goes in the cleanup slice).

## Consequences

The calls the weaver synthesises and the template splices have checker callee
sites keyed by spans of their own, so the name-based fallbacks of the MSIL and
JVM backends for them (D336 item 6) can be deleted (the 2d session owns that).

## Splices resolve in the consuming package

A template body is checked where it is spliced, so the names it uses have to
resolve there. The weave adds the template's own package and every package its
file imports to the consuming file (`withTemplateScopeImports`: whole-package
imports, `import extern` copied as written), as the consumer would have to
write them. The census over every library's tests and the examples found what
that still needs of a template:

- **A value the body names must be `pub`.** `idempotencyLedger` and
  `deadLetterStore` (lyric-mq) and `functionCacheStore` and `itemCacheStore`
  (lyric-cache) were private module values that only a backend's bundle-wide
  lookup reached from the consuming package; they are `pub` now, with a note that
  the body is spliced elsewhere.
- **A name that two imported packages both declare is written qualified.** The
  consumer now imports `Resilience` and its kernel package, which both declare
  `sleepMs`, `circuitIsOpen`, `circuitRecordSuccess` and `circuitRecordFailure`;
  the Retry and CircuitBreaker bodies call them as `Resilience.<name>`.

A third-party template that does neither now fails at the consuming aspect with
T0020 or T0123 and "in code generated for this declaration".
