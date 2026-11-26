# D510 - Loop invariants on TIR: asserted each iteration and when the loop ends normally

**Status:** accepted, implemented as `Lyric.Tir.Loops` (docs/70 phase 3c, §7.2; the TIR counterpart of the AST pass's loop-invariant lowering)

## Decision

1. **`TsInvariant(expr, text)`** carries the clause's formatter-rendered text (the builder records it), as `precondTexts` does for contracts: TIR has no source text. `Lyric.Tir.Walk`, mono, contracts, verify and the native fallback name follow the new shape.
2. **`Lyric.Tir.Loops.lowerLoopsBundle`** (`Pipeline.pipeLoopsTir`) rewrites each loop with invariant statements at the head of its body as the AST pass does: every `TsInvariant` becomes `assert(clause, "LoopInvariantViolated: invariant <clause>")` (so the clause is checked at the top of every iteration: the first checks the entry state, each later one that the body re-established it), and the clauses are checked again when the loop ends normally (the condition went false or the iterator ran out, including a loop that never ran). A `break` leaves with no obligation, and a `while true` has no exit check. Like range checks and protected-type invariants these are system checks, never gated by the contracts switch (#7645).
3. **A `while` becomes a `loop`** whose first statement is `if not cond { <exit checks>; break }`: the body's own `break` skips that branch, so no flag is needed, and a `continue` re-evaluates the condition as before. A **`for` keeps its form**: when a `break` leaves it, a `var __loop_broke` flag is set ahead of each such `break` and the exit checks are guarded by `not flag`; a clause that reads a name the loop pattern binds is checked per iteration only (#7381), the name being out of scope afterwards. A nested loop's unlabelled `break` is its own and never sets the outer flag; a lambda is not entered.
4. **`Lyric.Tir.Walk`** gains a statement hook, `Walker.preStmt` (a required field, built through `newWalker(pre, post)` for the two-hook form: the seed compiler cannot resolve a lambda field default across packages), which replaces a statement with a list of statements.
5. **Order**: after `?` lowering; the native bridge runs `pipeLoopsTir` right after `pipePropagateTir`. Node ids from 770,000,000, locals from 1,570,000,000.

## Not done

A `loop { }` takes no `invariant:` clause in source (the parser attaches them to `while` and `for` only), and a `for` over a range or collection that breaks through a labelled `break` of an outer loop is marked only when the label names it.
