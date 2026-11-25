# D503 - `?` lowered on TIR, and one rewriting walker for TIR passes

**Status:** accepted, implemented as `Lyric.Tir.Propagate` and `Lyric.Tir.Walk` (docs/70 phase 3c, §7.2)

## Decision

1. **`Lyric.Tir.Walk.walkExpr(walker, e)` is the shared rewriting traversal** of TIR: it rebuilds an expression bottom-up over every `TExprKind`, statement and pattern, offering each node to a `pre` hook (which may replace it and stop the descent) and a `post` hook (which sees the rebuilt node). A pass that rewrites one node kind writes a hook and not thirty traversal cases. `Lyric.Tir.Mono` and `Lyric.Tir.Contracts` keep their own traversals (they renumber nodes and substitute) and may move onto it later.
2. **`Lyric.Tir.Propagate.lowerPropagateFn`** replaces each `XPropagate(e)` by a block that binds the operand and matches it: success yields the payload, failure `return`s the failure rebuilt at the function's declared type (`Err(x)` at `Result[U, E]`, `None` at `Option[U]`), the symbols being `Std.Core`'s cases found through the interner. A `Result` operand needs a `Result` function result with the same error type and an `Option` operand an `Option`; anything else is reported in the result (`PropResult.diags`) and left as written. A lambda's result is its own function type's. Generators are left alone. `lowerPropagateBundle` and `Pipeline.pipePropagateTir` apply it to a bundle; it runs before monomorphisation.
3. **Operand-position hoisting is not part of it.** The AST pass's ANF hoist (`Lyric.HoistEngine`, #6448) exists for stack-machine backends, which cannot `return` with operands pushed; it belongs with await hoisting, the last TIR pass (§7.2), and applies to the `return`s this pass introduces as to those the user wrote. The native backend, which lowers to LLVM, does not need it.
4. **Census.** `lyric build --verify-ir` prints an `I0003 propagate census` line per package; `tir-census.sh` counts it toward its gate.

## Not done

Nullable (`T?`) propagation (the AST pass reports F0020 for it too), `?` whose operand and result differ in error type (the checker defines whether a conversion applies), and the hoist.
