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
JVM backends for them (D336 item 6) can be deleted. A name a template body
uses must resolve in the consuming package; the census below lists what that
required.
