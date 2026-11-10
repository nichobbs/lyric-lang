# D561 — SDK-bound ecosystem backends move to one monorepo

**Status:** accepted

Resolves Q-ECO-001 of docs/71 (D552).

Decision (project lead, 2026-11-10): the SDK-bound backends extracted in docs/71
phase 4 live in a single new repository (`lyric-ecosystem`), with one package
per backend, each versioned independently and each running the published
conformance suite. A backend whose release cadence later demands it can be split
into its own repository. Q-ECO-002 (compatibility policy between a library's
interface version and an external backend) and Q-ECO-003 (lyric-search's JVM
state) remain open.
