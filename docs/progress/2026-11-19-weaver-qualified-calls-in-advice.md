# Qualified calls in woven aspect advice resolve (D596)

The alias rewriter runs before the weave, so a package-qualified call in advice copied from another package's template (`Resilience.sleepMs(delay)` in `Resilience.Retry`) stayed a member chain and the checker recorded no callee for it: the B-mode specialisations of lyric-resilience's tests were unbuilt in the typed IR. `pipeWeaveEarly` now folds each generated batch with the alias rewriter before respanning it. Test: the `bmode_qualified_calls` check in `scripts/ci/tir-builder-shapes-e2e.sh` (34 of 34 bodies, tests pass).
