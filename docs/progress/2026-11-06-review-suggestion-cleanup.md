# Review suggestion cleanup (2026-11-06)

Non-blocking review suggestions from recent PRs (#8801, #8837, #8848, #8849):

- `Plan.planTree` (lyric-access) numbers the focus only when it is a live node of the tree, and
  falls back to the root otherwise, so a stale focus id no longer takes a number that survives
  until the next plan. Covered by a new `plan_tests.l` case.
- docs/70: re-wrapped the phase 2d MSIL bare-import sentence and removed the phase 3a clause that
  said the checker does not yet report an unsolved type argument.
- `noteUnsolvedCaseCtor` header comment reworded.
