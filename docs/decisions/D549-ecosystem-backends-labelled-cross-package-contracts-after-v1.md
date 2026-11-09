# D549 — Ecosystem backends ship labelled; cross-package contracts follow v1.0

**Status:** accepted

Context: several ecosystem libraries have backends that return
`NOT_IMPLEMENTED` or do not exist (lyric-storage S3 and Azure Blob, the lyric-mq
brokers, Hangfire and Quartz.NET on dotnet, lyric-db on the JVM). The first
version of this entry also listed lyric-mail JVM SMTP and lyric-search, which
their READMEs report as implemented (#7462, #5408); corrected 2026-11-09. docs/70 phase 6 (cross-package contracts) depends on phases 2 to 5,
which are still in progress.

Decision (project lead, 2026-11-09):

1. Libraries with unimplemented backends ship in v1.0, with the status labelled
   in each library's README and in the library availability matrix of
   `book/chapters/29-application-libraries.md`. An unimplemented backend returns
   an explicit `NOT_IMPLEMENTED` error. Each library keeps its own versioning
   (G4, D066).
2. Cross-package contracts (docs/70 phase 6) are not part of v1.0. At 1.0 a
   restored library's `requires:` and `ensures:` clauses are not enforced across
   the package boundary for its consumers. The v1.0 release notes state this.

Recorded in `docs/01` section 0.1, the book, and the v1.0 exit checklist of
`docs/12-todo-plan.md` (criterion 9).
