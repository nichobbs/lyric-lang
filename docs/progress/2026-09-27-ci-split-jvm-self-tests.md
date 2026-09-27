# CI: JVM self-tests split across two jobs (#7589)

`compiler-self-tests-jvm` ran about 10 minutes of JVM self-tests on one
runner and set the pace of every CI run after the stage-2 move
(2026-09-27-ci-stage2-jvm-tests-in-build-stage2.md). The job is now split at
its "JVM batch 2" barrier:

- `compiler-self-tests-jvm` keeps the first half (bitwise and coverage
  smoke through batch 2), about 4.8 minutes of steps.
- `compiler-self-tests-jvm-b` runs the rest (batch 3 onward: control-flow,
  stdlib and ecosystem JVM suites, lyric-web/ws Undertow smokes, the
  Maven-backed suites and the sequential tail), about 5.4 minutes.

Both jobs share the same `has_jvm_changes` gate and setup, both end in the
"Fail job if any batch failed" gate, and `build-and-test` aggregates both.
No test moved between targets or was dropped; the split point is an
existing `wait-all` barrier, so no background step straddles the two jobs.
The Maven-resolver `flock` serialization only ever coordinated steps that
are all in the second half.
