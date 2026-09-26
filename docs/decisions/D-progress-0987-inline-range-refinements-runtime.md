# D-progress-987 — Inline range refinements are checked at runtime

**Status:** shipped

Part 1 of #7226.

An inline refinement such as `Int range 0 ..= 9` erases to its base type in
every backend. T0015 rejected an out-of-range literal initializer, and
nothing checked any other value. So parameters, return values and
non-literal or reassigned bindings could hold anything, which made range
types unusable for constraining library parameters.

The contract elaborator now makes the refinement a runtime contract
(`contract_elaborator/range_checks.l`). The bounds are read exactly as T0015
reads them: `..=` and `..= hi` inclusive, `..` half-open, `lo ..` unbounded
above.

- **Parameters.** A refined parameter is checked on entry, before the
  function's `requires:` clauses, which may rely on it.
- **Return type.** A refined return type is one more `ensures:` on `result`.
- **Bindings.** A refined `val`/`var`/`let` is checked after its
  initializer.
- **Assignments.** A refined `var` or `out`/`inout` parameter is checked
  after every assignment, including compound assignments and assignments in
  expression position.
- **Scope.** Assignments resolve through a scope stack. A later binding of
  the same name shadows the refinement: an inner `var`, a pattern, a `for`
  binder, a `catch` binder or a lambda parameter. A lambda assigning a
  captured refined `var` is checked.
- **Messages.** A failure reads
  `RangeViolated: <owner> <parameter x | result | x> must be in <type>`.
  NaN satisfies no range, since the comparisons are the IEEE ordered ones
  fixed in D-progress-975.

`elaborateFunctionBody` now takes the function's parameters and return type.
Functions and protected entries with a refinement no longer take the
nothing-to-elaborate fast path.

The walker covers every expression form that holds a sub-expression, with
no catch-all, so an assignment inside a list, tuple, index, interpolation,
type application, `yield` or range bound is checked too (#7398). A lambda
kept in a list was skipped before, and the fast-path gate uses the same
walker, so such a function was not instrumented at all.

Not covered:
- A module-level `val` with a refined type keeps only the compile-time T0015
  check.
- An assignment through a field path (`w.field = v`) to a range-refined
  record field: the refinement is on the field's declared type, which this
  pass does not see.
- Named range subtypes (`type Cents = Long range ...`) are part 2 of #7226:
  their `from`/`tryFrom` already check, and derived arithmetic is re-checked
  through `from` by D-progress-992 (#7361).

Tests: `range_refinement_self_test.l` (7 cases, dotnet and JVM) covers
parameters, a half-open return, `Double` (including NaN) and `Long` bounds,
a non-literal binding, repeated and compound assignment, shadowing, and a
lambda assigning a captured refined `var`, held directly or in a list or
tuple.
