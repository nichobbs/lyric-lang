# Node identity, docs/70 phase 3a step 3 (#8613)

D325.

- `Expr`, `Statement` and `Pattern` carry `nodeId: Int = 0`.
- `Lyric.Resolve.renumberNodeIds` / `nodeIdsOf` (`resolve/resolve_nodeids.l`):
  dense, unique, post-order ids after the last expansion; the parser leaves 0.
- The AST mapper reaches patterns through `AstMapper.pat` / `mapFileNodes`.
- Tests: three cases in `resolve_self_test.l`.
- Next in 3a: the section 5 type rules, then the per-node tables and the builder.
