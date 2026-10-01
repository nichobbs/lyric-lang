# Open tuples: sub-tuple names, type parameters, matched literals (#7863)

#7855 typed an unannotated tuple's open elements (`None`, `Ok(...)`,
`Err(...)`, `newList()`, `newMap()`) from the uses of the tuple and of the
names its patterns bind. Three shapes were still left open.

**A name bound to a nested sub-tuple.** Only a name bound at an open
element's own position was open to it. With `val (inner, n) = ((None, 1), 2)`,
a use of `inner` fixed nothing, and on dotnet the `None` was built as an
`Option<object>`:

```lyric
val t = ((None, 1), 2)
val (inner, n) = t
pairValue(inner) + n      // pairValue(p: in (Option[Int], Int))
// dotnet: InvalidCastException; jvm (newList element): J008
```

**A type parameter reached through a pattern-bound name.**
`recordTuplePatternBinding` spelled the element's type through
`typeExprForRef`, which has no spelling for a type variable, so a name typed
`List[T]` was not recorded. The JVM reads a tuple element as an erased
`Object`, so `val (xs, n) = t; xs.add(x)` in a generic body failed with J008.

**A tuple literal matched directly.** `match (None, 5) { case (o, n) -> ... }`
had no binding to carry an annotation, so it was never an open site: dotnet
built `Option<object>` ("match not exhaustive"), and a `newList()` element was
an erased `Object` on the JVM (J008).

## Fix

- **Sub-tuple names.** `bindOpenTuplePattern` binds a name at a position
  that holds children deeper down to a site of its own (`openSiteAtPath`),
  keyed by the name's span. Its children are the owning site's children
  below that position, so a use of the name is a use of each of them, and a
  pattern over it (`val (o, k) = inner`, `match inner`) binds through it in
  turn. It is owned by the site it was bound from (`parentKey`), so it writes
  no annotation of its own; `resolveOpenBindingSites` still records the names
  patterns bound from it. A name a `match` arm binds to the whole tuple is
  open to the tuple's own site.
- **Type parameters.** `recordTuplePatternBindings` and
  `recordTuplePatternBinding` take the enclosing function's type parameters
  and spell the element type with `typeExprForOpenBinding`, which names a type
  parameter in scope. `Lyric.Mono` substitutes it when it specialises the
  body, as it already does for open-binding stores (#7788) and hoisted
  operands (#7823). This applies to every tuple pattern, not only open ones:
  `val (xs, n) = p` with `p: (List[T], Int)` is recorded too.
- **Matched literals.** `inferMatchExpr` registers a tuple-literal scrutinee
  as an open tuple site, as a binding's initializer is, and binds each arm's
  pattern through it. The resolved type is recorded in
  `localBindingTypeSites` under the literal's span, and
  `Lyric.Mono.tupleScrutineeTypedMono` rewrites the scrutinee to
  `{ val __lyric_ts_<n>: <type> = (...); __lyric_ts_<n> }`, the typed-local
  shape #7818 uses for list literals. Mono infers the arms' pattern types
  from the wrapped scrutinee.

Also from the #7867 review:

- `exprIsHoistExempt` is the one test for a hoisted operand that needs no
  recorded type (a literal, a lambda, a local). `hoistBindsOperand` and
  `recordHoistOperandType` both call it.
- `collectOpenTupleChildren` makes one pass over a tuple literal's elements.
  It returns whether every open element qualifies and collects the candidates
  (`OpenTupleChildren`). `registerOpenTupleSite` registers them only once the
  whole literal qualifies, replacing the separate `openTupleElemsQualify`
  pass.

## Tests

`lyric-compiler/lyric/expected_type_propagation_self_test.l` has 4 new
dual-target tests and one new awaiting case, using `None`, `Ok`/`Err`,
`newList()` and `newMap()`:

- names bound to a nested sub-tuple: a sink, a destructured literal,
  stores through a destructured sub-tuple, a match arm, two levels down,
  and an arm binding the whole tuple;
- type parameters: a destructured and a matched `newList()`, a `newMap()`,
  `None` and `Ok`/`Err` fixed by a reassignment, and a typed
  `(List[T], Int)` parameter;
- a tuple literal matched directly: `None` (beside a `Some(x)` arm),
  `Ok`/`Err`, `newList()`, an arm binding the whole tuple, a generic body,
  and an awaited element;
- wider tuples with open elements apart: `(None, 3, Ok(1))` passed and
  destructured, a nested 3-tuple, and a 4-element matched literal.

Results:

- dotnet before: 6/10. Sub-tuple names, matched literals and wider tuples
  failed (`InvalidCastException`, "match not exhaustive"), and so did the
  awaiting test (its matched-literal case). The type-parameter test passed:
  the tuple's own annotation already carried `T`.
- jvm before: the file did not compile (J008). Each gap fails on its own in
  a separate repro: sub-tuple names, type parameters and matched literals
  each give J008.
- after: 10/10 on both targets.

`typechecker_self_test.l` has 3 new tests. They check the recorded tuple type
and pattern-binding type for a sub-tuple name, for a `List[T]` element, and
for a matched literal.

The test file was already in `compiler-self-tests-batch.sh`,
`jvm-generics-self-tests-batch.sh` and `scripts/ilverify-selfhosted.sh`
phase 4. The rules are documented in docs/01 §4.3 and book §12.4.
