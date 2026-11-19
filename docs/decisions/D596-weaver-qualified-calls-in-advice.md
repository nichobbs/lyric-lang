# D596 - Package-qualified calls in woven aspect advice are folded like the consumer's own (docs/70 phase 3a, #8613)

**Status:** shipped.

## Context

The alias rewriter folds a qualified member chain (`Resilience.sleepMs(ms)`, the parser's `EMember(EPath Resilience, sleepMs)`) into the flat `EPath` the checker resolves a package's function through. It runs in `pipePrepareForCheck`, before the weave. Advice copied from another package's aspect template into a function or B-mode specialisation (`__lyric_bmode_Resilience_Retry__...`) is generated after it, so a qualified call in the template stayed a member chain. The checker read it as a member call on a type named `Resilience`, resolved no signature, recorded no callee and typed the callee `<error>`: the specialisations of `Resilience.Retry` and `Resilience.CircuitBreaker` in lyric-resilience's tests were unbuilt (I0002), four calls in all (`sleepMs`, `circuitIsOpen`, `circuitRecordSuccess`, `circuitRecordFailure`).

## Decision

`pipeWeaveEarly` runs the alias rewriter over each generated batch before respanning it. A template's bare names already resolve in the consumer's scope, so its qualified names are read through the consumer's imports as well; the rewriter treats a synthesised item with the union of the file's imports and leaves an already flat path alone.

## Results

`bmode_qualified_calls` in `scripts/ci/tir-builder-shapes-e2e.sh` runs lyric-resilience's tests with `LYRIC_VERIFY_IR=1`: every body of `resilience_tests.l` builds (34 of 34, was 32) and the tests pass.
