# `@projectable` `tryInto` checks invariants (docs/70 phase 3c, #9315)

Decision: D511.

## What shipped

- `tryInto` returns `Err("InvariantViolated: Pkg.T invariant <clause>")` instead of panicking when the view's values violate an `invariant:` clause of the opaque type (`Lyric.ContractElaborator.invariantErrChecksText`, used by `Lyric.Projectable`).
- docs/01 §2.9, the book (chapters 8, 9, appendix B) and the §6.2 not-covered list updated; no `ContractViolation` type.
- Runtime tests on dotnet (`msil_self_test_m87.l`) and the JVM (`projectable_jvm_self_test.l`), and an expansion test in `projectable_self_test.l`.
