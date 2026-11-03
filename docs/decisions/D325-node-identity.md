# D325 - Node identity: `nodeId` on expressions, statements and patterns, numbered by `Lyric.Resolve` (docs/70 phase 3a, #8613)

**Status:** shipped (numbering and tests). Step 3 of docs/70 §13 phase 3a,
after D319 and D323. Nothing reads the ids yet; the per-node tables and the
TIR builder do.

## Context

docs/70 §6.1 gives every expression, statement and pattern a `NodeId` that is
dense and unique per package whatever generated the node, so the checker's
`*Sites` tables can be keyed by it and TIR nodes can name their source.

## Decision

1. `Expr`, `Statement` and `Pattern` (`parser_ast.l`) gain
   `nodeId: Int = 0`. The default keeps the several hundred existing
   constructions (the parser's `mkExpr`/`mkPat`/`mkStmt`, and every pass that
   builds nodes) unchanged. `Lyric.Tir.NodeId` wraps the same integer.
2. **The parser does not assign ids.** Its constructors are stateless helpers
   called from hundreds of sites, and any pass that rebuilds a node (the
   weaver, mono, derives, wire and plugin expansion, the contract elaborator)
   makes a new one with id 0, so ids assigned at parse time would be lost or
   stale by the time anything reads them. This resolves §6.1's wording ("the
   parser gives every node a NodeId, and Lyric.Resolve renumbers") as: ids are
   given once, by `Lyric.Resolve.renumberNodeIds`, after the last expansion.
   A pass must not carry ids across a rewrite.
3. `renumberNodeIds(file): NumberedFile` numbers every node of a file post-order
   (a node's id exceeds its children's), dense from 1, contract clauses and the
   bounds of range patterns included; `NumberedFile.count` is the highest id.
   `nodeIdsOf(file)` lists the ids in traversal order. Numbering is idempotent
   in the ids it produces.
4. To reach patterns the existing post-order AST mapper
   (`Lyric.ContractElaborator.ast_map`) gains `AstMapper.pat` (`None` keeps the
   old reach: patterns untouched) and `mapFileNodes(file, expr, stmt, pat)`.
   A node the mapper rebuilds keeps the `nodeId` of the node it replaces when it
   reaches a callback, so a callback can read it; a callback that builds a new
   node chooses the new id. Existing callers are unchanged.
5. Ids are per file for now: the numbering of an assembled multi-file package
   (one counter across its files) is the builder's call, and uses the same
   function over each file with a running base when it lands.

## Consequences

No behaviour change: nothing is wired into the pipeline, so a compile pays no
cost. The entry point is called by the checker's per-node tables (next in 3a).
`resolve_self_test.l` covers unnumbered-after-parse, uniqueness and density,
patterns (arms, tuple bindings, range patterns) and idempotence.
