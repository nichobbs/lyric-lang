# D511 - `@projectable` `tryInto` checks the invariant clauses and returns `Err`

**Status:** accepted (owner decision on #9315, 2026-11-25: option B), implemented in `Lyric.Projectable` (docs/70 phase 3c; extends D761's expansion)

## Decision

1. **`UserView.tryInto(self): Result[User, String]` keeps its signature** and no `ContractViolation` type is introduced. When the opaque type declares `invariant:` clauses, `tryInto` first checks each clause on the view's values and returns `Err("InvariantViolated: Pkg.User invariant <clause>")`, the construction checker's message naming the first clause that fails, and only then rebuilds the value through the constructor (which cannot fail the check any more). A type with no invariant keeps the one-line `Ok(User(...))` form. docs/01 §2.9 and the book (chapters 8, 9 and appendix B) state `Result[User, String]` and the checking behaviour.
2. **The checks are source text built from the same clauses as the construction checker**: `Lyric.ContractElaborator.invariantErrChecksText` substitutes each field `f` by `self.f` in the clause, keeps its runtime-checkable conjuncts (a quantifier cannot run), and renders `if not (<clause>) { return Err("<message>") }`, so the message and the clause text are exactly those `__lyric_checked_User` asserts with. `Lyric.Projectable` places them ahead of the `Ok(...)`; the declaration is ordinary AST, so the checker, the TIR builder and every backend treat it as any function (dotnet, JVM; native refuses `@projectable`, N0101).
3. **Tests**: `projectable_self_test.l` (the expansion), and runtime cases in `msil_self_test_m87.l` and `projectable_jvm_self_test.l` (a view violating `used <= limit` returns `Err` naming `Quota invariant used >= 0 and used <= limit`; a valid one round-trips).
