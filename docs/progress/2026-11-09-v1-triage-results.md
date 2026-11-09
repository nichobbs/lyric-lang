# v1.0 triage results (streams S1-S6)

Six agents re-checked the Tier 1 clusters in `docs/12-todo-plan.md` against
`main`.  Most listed issues were already fixed and closed with a regression
test, so the tier list had drifted; `docs/12` now records which.

- **Security (S1).**  Of the eight security-labelled issues, six were already
  closed.  #7249 (lyric-web) and #7241 (lyric-db) are fixed on `main` and are
  now closed, verified by reading the code and the existing tests (not re-run).
  Residuals: lyric-db has no JVM backend (#8932), lyric-web has no explicit
  `allowAnyOrigin` opt-in (#8933).
- **Verifier (S2, PR 8924).**  #8142, #8354, #8157, #8141 and #8306 were already
  fixed and pinned by tests.  #8110 had a real hole (an undeclared method was a
  congruent function, so `xs.add(1)` did not invalidate an earlier `xs.count`);
  it now fails closed with V0033 (D546).  #8110 stays open for three residuals.
- **CLI (S3, PR 8922).**  #8321, #8362, #8245 and #8311 were already fixed; the
  remaining commands (`restore`, `publish`, `init`, `add`, `remove`,
  `public-api-diff`, `repl`, `lsp`, `version`) now reject unknown options and
  surplus arguments.
- **dotnet codegen (S4).**  All twelve issues were already fixed.  #8229 and
  #8318 are fixed by rejecting `out`/`inout` on `async` functions (T0183), not
  by a lowering fix.  #7963 was closed as not reproducible with the self-hosted
  emitter (the stage-0 repro was not re-run).
- **Checker (S5, PR 8926).**  Unknown `List`/`Map`/`Set` members are T0113.
  #7978, #7786, #8161, #8249, #8289, #8331, #8334 and #8104 items 1-2 no longer
  reproduce; #8104 item 3 (native bare sibling calls) stays open.
- **Release hygiene (S6, PR 8923).**  Channel-status table, stability walk,
  baseline procedure.  The baseline cut is blocked by #8927; four `_kernel/`
  packages have no tier (#8928).
- **Build.**  `make lyric` fails at the AOT step on NU1903 (#8929); four agents
  worked around it with `-p:NuGetAudit=false`.
