# D552 — Ecosystem libraries ship an interface, a reference backend and a conformance suite; SDK backends become separate packages

**Status:** accepted

Supersedes the first item of D549 (stub backends ship labelled with
`NOT_IMPLEMENTED`). D549's second item (cross-package contracts follow v1.0)
stands.

Context: the 2026-11-09 ecosystem audit (docs/71) found seven libraries whose
headline backend returns `NOT_IMPLEMENTED` or does not exist (lyric-mq,
lyric-storage, lyric-db on the JVM, lyric-jobs, lyric-otel, lyric-lambda,
lyric-aws-secrets on native). Shipping a named backend that only returns an
error conflicts with the production-readiness standard in `CLAUDE.md`.

Decision (project lead, 2026-11-09):

1. Each ecosystem library keeps its **interface**, one **real in-tree
   reference backend** (in-process, in-memory or local filesystem), and a
   **conformance suite** published from `lyric-testing` so any backend runs the
   same contract tests.
2. A backend that is not implemented is **removed from the public API**, not
   shipped as `NOT_IMPLEMENTED`. A library is marked stable for the backends it
   has.
3. SDK-bound backends (AWS, Azure, RabbitMQ, Kafka, Hangfire, Quartz.NET,
   Elasticsearch, Meilisearch, Redis, JDBC drivers) move to **separate
   packages**, in a separate repository for ecosystem implementations. The
   extraction is deferred until docs/71 phase 1 lands and the registry flow
   (docs/39) is usable, because cross-package generics and aspects must work
   first. Repository layout (one monorepo or one per backend) and the
   compatibility policy are open (Q-ECO-001, Q-ECO-002 in docs/71).
4. Stability is a **manifest field**, `[package] stability = "stable" |
   "experimental" | "incomplete"`, checked by `lyric publish`, and mirrored in
   each README and the chapter 29 matrix.
5. JVM parity is **not a hard gate for v1.0**. A library may be `stable` with a
   documented JVM gap tracked by an issue.
6. Graphics, UI and native-only libraries are out of scope for this work
   (D548).
