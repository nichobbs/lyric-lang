# D366 - The expression builder: structural kinds first, everything else an I0002 by kind (docs/70 phase 3a, #8613)

**Status:** first slice shipped (`Lyric.Tir.Build`, `build_expr.l`).

## Context

D360-D365 gave the builder its inputs: a type per expression and a callee per
call, keyed by `NodeId`. docs/70 §6.3 asks the builder to turn a checked
function body into `Lyric.Tir`, failing with I0002 on any node the checker did
not record, and §12.2 to run it beside the pipeline until its census is zero.

## Decision

1. `buildFnBody` builds a non-generic function body, numbering the locals
   itself (`BuildEnv`: scopes of `LocalDecl`s, a local counter). Parameters
   become the outermost locals, typed by `resolveType` and `tyOfType`.
2. This slice builds the kinds that need nothing beyond a node's type and the
   local scope: literals, locals, tuples, lists, interpolation (a non-`String`
   part goes through the built-in `toString`), the primitive prefix and binary
   operators as `Callee.Intrinsic`, the short-circuit operators as `XShort`,
   `if`, blocks, `unsafe`, `await`/`spawn`/`yield`/`?`/`old`/`result`, and the
   statements `val`/`let`/`var` of one unannotated name, `return`, `break`,
   `continue`, `while`, `loop` and expression statements. A last expression
   statement is a block's value unless the block is `Unit`.
3. Every other kind is not built: the builder records an I0002 line naming the
   kind and position and counts it by kind (`BuildEnv.uncovered`), and returns
   no node. It never produces a node it cannot stand behind.
4. `LYRIC_VERIFY_IR=1` reports, beside the type and callee censuses, how many
   function bodies the builder builds and the kinds it has no case for, ranked
   (`buildCensus`, `buildCensusLines`).
5. Recording fixes the builder found. Three typing paths never passed through
   `inferExpr`, so their nodes had no recorded type: an expression typed against
   an expected type (`inferExprExpected`), and an `if` or `match` typed by
   `inferIfExpr` and `inferMatchExpr` (reached directly from block tails). Each
   now records its node's type, replacing an earlier entry as re-inference does.

## Census at this slice

Over `lyric-stdlib/tests/*_tests.l`: 20 of 1148 function bodies build. The kinds
with no case, by nodes: a call (3212), a match (484), an annotated binding
(312), an assignment (171), a name that is not a local (133), a member access
(83), a for loop (40). Calls, with their argument order and conversions, are the
next slice.

## Not covered

Calls, constructors, fields, indexes, `match` and patterns, lambdas and
captures, assignments and places, annotated bindings, generic functions,
contracts, the conversion points, and `TPackage` assembly with the verifier.
