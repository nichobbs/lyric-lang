# D-progress-981 — Loop invariants are checked on normal loop exit

**Status:** shipped

Closes the last open item of #7224.

A loop `invariant:` was lowered to an `assert` at the top of the loop body
only. That checks the entry state and every state the body re-establishes
before another iteration, but not the state in which the loop ends. The
`while` rule in docs/08 (`ι ∧ ¬c ⇒ Q`) needs the invariant exactly there. So
a loop whose invariant failed only in its final state passed silently, and a
loop whose body never ran was never checked at all.

The contract elaborator now appends the check after each `while` and `for`
that carries an invariant:

- With no `break` leaving the loop, the asserts follow the loop directly.
- Otherwise every such `break` first sets a fresh `__lyric_loop_broke_<n>`
  flag, and the post-loop asserts are guarded by `if not <flag>`. A `break`
  exit carries no invariant obligation.
- A `break` counts as leaving the loop when it sits directly in the body
  (whatever label it names), or inside a nested loop when it names this
  loop's label.
- The walk descends into `if`/`match`/block/`unsafe` expressions, `try`,
  `scope`, and `val`/`var`/assignment right-hand sides. It does not enter
  lambdas.

`do` loops have no normal exit and are unchanged.

A `for` invariant clause that reads a name bound by the loop pattern
(`for i in 0 ..< n` with `invariant: i < n`) is checked on every iteration
but not on exit. After the loop that name is out of scope, or would resolve
to an unrelated outer binding the pattern shadowed (#7381). The loop's other
clauses keep their exit check.

Labelled loops are specified but not parsed today, and every backend
treats `break label` as a plain `break`. That miscompile is tracked in
#7349. The elaborator's label rule is already the one that issue needs.

Tests:
- `loop_invariant_self_test.l` adds exit-only, zero-iteration, `break`,
  inner-`break` and `for` cases (including pattern-variable, shadowed and
  mixed clauses), and now runs on both targets.
- `contract_elaborator_self_test.l` pins the lowered shape.

Docs: language reference §contracts (loop `invariant:` bullet), book chapter
17.
