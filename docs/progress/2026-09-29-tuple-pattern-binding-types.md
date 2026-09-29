# Names bound by tuple patterns carry their element types on both targets (#7728, #7730)

Both backends represent a tuple as a list of boxed elements, so a name a tuple
pattern binds holds the boxed element unless codegen can see the tuple's
element types at the pattern. It often could not:

```
func sumPairs(): Int {
  val pairs: List[(Int, Int)] = [(1, 2)]
  var t = 0
  for (a, b) in pairs { t = t + a + b }
  t            // dotnet: -2147378704, expected 3
}
```

- `--target dotnet` (#7728) silently miscompiled every `for` loop with a
  tuple pattern over a list. The list protocol in `emitCollectionForMsil`
  narrowed an element only when it was a record or union class, so a tuple
  element was bound as `object` and lost its element types. The pattern then
  bound each name as `object`, and `a + b` added the boxes' object
  references. The same held for a `for` inside a closure or an async
  generator. `val (a, b) = pair` and `match` were correct, because there
  codegen tracked the tuple's element types from the scrutinee.
- `--target jvm` (#7730) bound every name a tuple pattern binds as `Object`:
  in a `for`, in an unannotated `val (a, b) = ...`, in a nested tuple, and in
  a `match` arm. Where one operand had a known type (`t + a`), codegen could
  infer the other. An operation between two such names (`a * b`, `a - b`,
  `yield a + b`, `s + toString(a + b)`) failed to compile with J008.

The type checker already knew each name's element type. The fix carries it to
codegen the way #7711 and #7716 carry function types:

- The type checker records each name bound at a tuple-pattern position in
  `SymbolTable.tuplePatternBindingSites`, keyed by the binding's span
  (`recordTuplePatternBindings`). It does this for `for` patterns, `val`
  patterns and `match` arm patterns, and through nested tuples and
  parentheses. Each record (`Lyric.Parser.TuplePatternBindingSite`) holds the
  element type spelled as source. Not recorded: or-pattern alternatives
  (every alternative must bind the same names), nullary union-case names,
  `Unit` and `Never` elements, and types with no source spelling, such as a
  type parameter or an element the checker could not type. If two checked
  patterns share one source position with different types (synthesized
  code), the site is marked conflicting and left alone.
- `Lyric.Mono.desugarCheckedFile` renames each recorded name to a fresh
  `__lyric_tp_<n>` in the pattern and binds the source name with
  `val <name>: <element type> = __lyric_tp_<n>`. Both backends already lower
  that hand-annotated form correctly. The binding goes at the start of a
  `for` body, right after a destructuring `val`, and at the start of a
  `match` arm's guard and body.
- `emitCollectionForMsil` also keeps a tuple element's `MTuple` type in the
  list protocol, as it keeps a record's class, so a tuple pattern the checker
  could not type still unboxes each element.
- A `for` over a call to an async generator that yields tuples now types its
  elements with the generator's declared tuple type, instead of the lenient
  `TyError` that every generator call's elements get, so the loop's tuple
  pattern is typed too.

Verified by the new dual-target `tuple_pattern_binding_self_test.l`, wired
into `scripts/ci/compiler-self-tests-batch.sh` and
`scripts/ci/jvm-generics-self-tests-batch.sh`. It has 22 cases. Each uses
the bindings directly in arithmetic, comparison or string concatenation, over
`(Int, Int)`, `(String, Int)`, `(Long, Double)`, `(Pt, Int)` and
`(Option[Int], Int)`, in these forms:

- `for` over a local list and over a parameter list
- nested `for ((a, b), c)`
- `val (a, b) = pair`, including the nested form
- `match` arms, including a nested pattern, a guard that reads the bindings,
  and an or-pattern of tuples
- a `for` and a `match` inside a closure
- `yield a + b` in an async generator
- a `for` over an async generator that yields tuples

Before the fix, dotnet failed 9 of the first 17 cases: every `for` case,
including those in a closure and a generator. The JVM rejected the whole file
at compile time (J008).

Not covered, a separate bug: a bare `None` inside a list literal is built as
`Option_None<object>` on dotnet even when the list is annotated with a
concrete element type. `val xs: List[Option[Int]] = [None]` throws
`ArrayTypeMismatchException` when the list is built. With
`List[(Option[Int], Int)] = [(None, 1)]`, reading the element back as
`Option[Int]` throws `InvalidCastException`, and a `match` on it finds no arm.
A `None` bound first to an annotated local (`val none: Option[Int] = None`)
works.
