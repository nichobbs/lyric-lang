# 2026-09-27 — MSIL: bare `None` in a tuple-valued branch takes the sibling branches' type (#7455)

A `match` arm or `if` branch whose value is a tuple literal with a bare
generic nullary case in it, such as `(Some(a), None)` beside
`(None, Some(b))`, built that `None` as `Option_None<object>` on
`--target dotnet`. A tuple element gets no construction hint unless the
tuple context is annotated (#4965). The sibling `Some(b)` built
`Option_Some<Box>`. Destructuring with `val (lo, hi) = match …` then threw
`InvalidCastException`. When the `None` arm came before any concrete arm,
or sat in an `if` branch, ilverify also rejected the join with
`StackUnexpected`. The existing forward-only running canon in
`lowerMatchExprMsil` (#3920) only covers arms that are entirely a bare
`None`. It cannot recover a type argument that is only fixed by a later
arm. The JVM backend was already correct because generics are erased
there.

The fix is in `lyric-compiler/msil/codegen.l`:

- **Deferred holes.** A match arm or if branch whose value is a tuple
  literal is lowered by `lowerBranchCollectingTupleHolesMsil`. The literal
  can be the body itself or the trailing value of a `defer`-free block. Each
  bare generic nullary element is recorded as a `TupleHoleMsil` (branch,
  instruction offset, tuple path, union) and emits nothing. Nested tuple
  literals recurse. Once every branch is lowered, `fillTupleHolesMsil` takes
  the most concrete same-union element type at the same tuple path from the
  sibling branches that fall through. It lowers the `None` under that hint
  and splices it into the recorded offset. Only a side-effect-free,
  scope-independent `EPath` is deferred, so lowering it after its branch's
  scope has closed gives the same code as lowering it in place. An annotated
  tuple context keeps the existing `collExpect` path.
- **No ambient hint in tuple elements.** A tuple element without an
  annotated expected type is now lowered in a cleared hint scope
  (`lowerTupleElemUnhintedMsil`). While that scope is active, the new
  `FuncCtx.retHintFallbackOff` depth also stops a hint-less case
  construction from borrowing the function's declared return type
  arguments. A `return` inside the element resets it for its own value.
  Before this, an enclosing `Option[String]` return type reached
  `(Some(b), 1)` through either route and built `Option_Some<string>`
  around a `Box`. That is the `StackUnexpected` (found `Expr`, expected
  `RangeBound`) that PR #7448 hit in
  `Lyric.TypeChecker.checkConfigFieldRange`.

The regression test is `lyric-compiler/lyric/tuple_nullary_case_self_test.l`
(11 tests). It covers `None` in the first, middle and last positions, `None`
arms before the concrete arm, block arms, `if` branches, nested tuples, a
returned tuple, a tuple call argument, a record constructor inside a tuple,
an enclosing `Option[String]` return hint, and a value-type `Option[Int]`
slot beside an early-return arm.
It runs on both targets and its dotnet output passes ilverify.

Three pre-existing MSIL gaps are outside this fix. None of them depends on
tuples:

- A generic case whose payload does not fix every type parameter, such as
  `Ok(v)` beside `Err(e)` in unannotated `match` arms, builds
  `Result<Int, object>` and `Result<object, String>`. The value then fails a
  cast or reports that the match is not exhaustive.
- An in-bundle generic union's nullary case (`Nothing` of `Maybe[T]`) in an
  unannotated `match` arm is not seen by the running canon, which only knows
  `Std.Core.Option`.
- An in-bundle generic union value that comes out of a destructured tuple is
  never `castclass`ed back from `object`. `val (m, j) = (Just(b), 1)` then
  fails ilverify at `m`'s first typed use.
