# Native: tuple literals take their component types from the expected type (#7824)

On `--target native`, `[(None, 1), (Some(2), 3)]` failed with N0007 ("cannot
infer the type arguments of generic union case 'None'"), even when the binding
was annotated `slice[(Option[Int], Int)]`.

#7818 types a list literal at its joined element type and binds it to a local
of that type, so the native backend does lower each element against the tuple
type `(Option[Int], Int)`. But `lowerExprExpecting` in `Lyric.LlvmCodegen` had
no case for a tuple literal. It fell through to the plain `lowerExpr`, which
lowers each component with no expected type, so a `None` component had nothing
to take its type arguments from. The same gap hit every other position that
carries an expected tuple type: a tuple return value, an annotated binding, an
argument, an assignment, a nested tuple, a record field and a union payload.

`lowerExprExpecting` now routes a tuple literal through
`tupleConstructForExpected`. When the expected type is a tuple of the same
arity, each component is lowered against its expected component type (the
native counterpart of MSIL's per-element `collExpect` push for `ETuple`), and
the tuple is built at exactly the expected layout. A `None`, `Some(..)`, `[]`
or lambda component now gets its representation from the tuple type. That
includes an inline `Option[Int]` struct, because the case is built against the
component's own `NType`.

Tests:

- `tuple_expected_type_self_test.l`: a new cross-target test with 6 cases:
  a literal of tuples holding `None` (iterated and passed), an annotated slice,
  tuple return values (expression body, `return`, `if`/`match` branches, a
  `Result` component), an annotated binding, an argument, an assignment, an
  empty-list component, nested tuples, a record field and a union payload.
  Native before: N0007 at compile time. After: 6/6 on native, dotnet and JVM.
  It runs in the native lane's cross-target loop, both batch scripts and
  ilverify phase 4.
- `llvm_collections_self_test.l`: two ASan cases with `String` payloads, so the
  ownership of each tuple component is checked. One covers annotated
  `slice` and `List` literals plus `List.add` of a tuple holding `None`. The
  other covers a return value, an argument, an assignment and a nested tuple.

Found while testing, not fixed here: on `--target dotnet`, a `List[(Option[Int],
Int)]` (a `List`, not a `slice`) loses its element type. `typeExprToMsilCtx`
lowers a `List` of tuples to the erased `MObject` (docs/59 §3 F10), so neither
`val ys: List[(Option[Int], Int)] = [(None, 7)]` nor `ys.add((None, 1))` passes
the tuple type to its elements. The `None` is built as `Option<object>`, and a
reader throws `InvalidCastException`. Native and JVM handle these programs.
This needs its own issue; the cross-target test covers `slice` only.
