# D548 — Native, wasm32, UI and graphics are outside the v1.0 SemVer guarantee

**Status:** accepted

Context: G1 (D-progress-620) settled the JVM channel only. Native (LLVM) and
wasm32 shipped after the v1.0 gates in `docs/36` were written, and the UI and
graphics libraries (docs/65, docs/67) are new and mostly verified on Linux.

Decision (project lead, 2026-11-09):

1. `--target native` and `--triple wasm32-wasi` are not part of v1.0. They are
   supported and tested but carry no v1.0 SemVer guarantee, and are versioned
   independently of the compiler, like `--target jvm`. Lyric SemVer at v1.0
   applies to the language and to the `@stable` standard library on
   `--target dotnet`.
2. `lyric-ui`, `lyric-window`, `lyric-gpu`, `lyric-gpu-window`, `lyric-text`,
   `lyric-draw`, `lyric-game`, `lyric-unicode` and `lyric-access` are
   experimental at v1.0: their APIs may change in any release.

Recorded in `docs/01` section 0.1 and in the open-decisions section of
`docs/12-todo-plan.md`. Still open there: how to treat ecosystem libraries with
`NOT_IMPLEMENTED` backends, and whether cross-package contracts (docs/70 phase
6) land before 1.0.
