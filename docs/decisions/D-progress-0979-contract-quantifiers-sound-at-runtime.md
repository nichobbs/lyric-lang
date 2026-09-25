# D-progress-979 — Contract quantifiers are skipped soundly at runtime; quantifiers only in contracts

**Status:** shipped

Part of #7228 (item 3, plus the grammar rule it depends on).

A `forall`/`exists` ranges over a type (`forall (i: Int) where ... { ... }`),
so a runtime-checked build cannot evaluate it. The MSIL and JVM backends
lowered each quantifier to the constant `true`, with an unlocated W0002
line on stderr. That is only sound where the quantifier sits in a positive
position: `requires: not (exists (i: Int) { ... })` became `false` and
failed on every call. Native could not lower quantifiers at all.

- **Elaborator.** Every runtime contract check is built by `mkAssertCall`:
  requires, ensures, loop invariants (including the #7224 exit check), type
  and protected invariants, and aspect contracts via the weaver. It now
  splits the clause into its top-level `and` conjuncts and drops each
  conjunct that contains a quantifier; the others are still asserted. A
  clause left with nothing to check asserts `true`. Dropping the whole
  conjunct is sound under any polarity.
- **W0002.** `runtimeQuantifierWarnings` scans function, method, entry and
  aspect contracts, type and protected invariants, and loop invariants. It
  reports W0002 as a real warning diagnostic at each quantifier's span. The
  pipeline runs it for files that are not `@proof_required`.
- **P0344.** The grammar has always said a quantifier may appear only in a
  contract, but the parser accepted one anywhere, and a body expression like
  `not (exists (i: Int) { i == 3 })` compiled to `false`. The parser now
  reports P0344 outside `requires:`/`ensures:`/`when:`/`decreases:` and
  `invariant:` clauses (`ParseState.quantifierAllowed`). `exists(p)` as an
  ordinary call is unaffected: the quantifier form needs `(name :`.
- **Codegen.** A quantifier can therefore no longer reach MSIL or JVM
  codegen. Those arms now fail as internal compiler errors, like `EOld`,
  instead of silently producing a constant.

Tests:
- `contract_quantifier_self_test.l` covers a negated quantifier in a
  precondition, a conjunct kept next to a quantifier, ensures, a loop
  invariant and a type invariant, on dotnet and JVM. Native has no
  `assertPanics`.
- `parser_self_test.l` adds P0344, a loop-invariant quantifier and
  `exists(p)` as a call.
- `silent_miscompile_guard_jvm_self_test.l` and `verifier_self_test.l`
  are unchanged and pass.

Still open on #7228: type-checking clause expressions, the `@pure` rule for
calls in clauses, and `when:` barriers.
