# Stdlib collection and monad checks key on type identity, not the bare name (#7737)

#7696 and #7702 made bracket-literal acceptance recognise the stdlib `List` by
its `Std.CollectionsHost` identity. The rest of `lyric-compiler/lyric/type_checker/`
still compared `TyUser` names against `"List"`, `"Map"`,
`"MapKeyCollection"`/`"MapValueCollection"`, or resolved `Result`/`Option`
through a shadowable bare-name lookup. A package declaring its own type with
one of those names was treated as the stdlib type, compiled, and then failed at
runtime on both backends, because codegen always builds or expects the genuine
stdlib type. Every site was audited. Each semantic check now goes through
`isStdCollectionsHostType(tbl, tid, name)` or a `Std.Core` package lookup.

## Sites fixed

- **`for` iteration** (`typechecker_stmts.l`, `SFor`): `List`,
  `MapKeyCollection` and `MapValueCollection` are recognised by identity. A
  user `record List[T]` now takes the existing Lyric-native single-parameter
  branch (**T0126**). Before the fix it compiled and then failed at runtime:
  `InvalidCastException` (`Repro.List`1` to `List`1[Object]`) on dotnet and
  `IncompatibleClassChangeError` (not `Iterable`) on the JVM.
- **Indexing** (`indexElementType`): `List`/`Map` element typing is
  identity-based. Indexing a Lyric-native record, union or enum is a new
  error, **T0143**. Neither backend has an indexer protocol for those types:
  MSIL falls back to an `IList` cast and the JVM to an `ArrayList` cast. So
  `l[0]` on a user `record List[T]` compiled and then threw
  `InvalidCastException`/`ClassCastException`. Extern, distinct, opaque and
  protected receivers keep the lenient path, where the backend resolves the
  index.
- **Built-in `List` members** (`builtinMember`, which now takes the symbol
  table): `.count`/`.toArray()` are typed only on the stdlib `List`. On a user
  `record List[T]` they suppressed the unknown-member check. On dotnet this
  produced `InvalidProgramException` at runtime; on the JVM it was a late
  `J009` codegen error. They are now **T0113** at type-check time.
- **Conversion hints** (`sliceListConversionHint`, renamed `typeMismatchHint`
  because it is the suffix every mismatch diagnostic appends):
  `.toList()`/`.toArray()` are suggested only against the stdlib `List`, and
  only when the conversion would produce the expected type. `["a"]` against
  `List[Int]` no longer suggests `.toList()`. Against a same-named user type the
  hint says the type only shares the stdlib name. When the two types in a
  mismatch render identically but differ in identity, the hint names both
  declaring packages ("the value is Std.Core.Result, the target is
  App.Result").
- **`tryFrom`'s `Result`** (range/distinct `T.tryFrom`): resolved from
  `Std.Core` by package. With a local `union Result[T, E]` it was typed as the
  local union, but both backends build `Std.Core.Result`. So matching the
  result on the local union's cases threw "match not exhaustive" at runtime on
  both targets. It is now a compile-time mismatch.
- **Method-spelling `.indexOf`/`.lastIndexOf`'s `Option`**
  (`stringIndexOfMember`): resolved from `Std.Core`.

## Left as name comparisons

- The `Result`/`Option` field accessors (`isStdCoreMonadType`), which were
  already identity-checked.
- `propagateUnwrap` (`?`): consistent by name with `Lyric.Propagate` and both
  backends' `?` lowering. A `?` over a package's own `Result` union runs
  correctly on both targets.
- `isPreludeName`: this is the prelude's name set.
- Display names on constructed types.

## Diagnostic text

An empty literal `[]` infers as `slice[<error>]`. Every mismatch site that has
the argument expression now describes it as "an empty list literal", for
example "argument for field 'n' is an empty list literal but field expects
Int". The sites are the named and positional constructor fields, call
arguments (T0043), `val`/`var`/`let` initialisers, assignments, `return`, and
expression-bodied function bodies. A non-empty literal keeps its inferred
`slice[T]` type and gets no `.toList()` advice.

## Verification

`typechecker_self_test.l`: 657 tests, 0 not ok. The 19 new #7737 cases pair
each shadowed form (a user `record List[T]`, `record MapKeyCollection[K, V]`,
`union Result`/`union Option`) with the stdlib form. The stdlib form uses
`stdCollectionsHostPackages()` (extended with `Map`/`MapKeyCollection`) or the
new `stdCorePackages()` harness, and each positive case also asserts that a
mismatching binding is rejected, so an element or result type that degraded to
`TyError` would fail it. Against the previous compiler, 13 of the new cases
fail. The remaining ones are stdlib-form regression guards. Two existing cases
that modelled the stdlib `List` with a local same-named declaration now use
the stdlib package harness. Repros on `--target dotnet` and `--target jvm`: the
runtime failures listed above are now type errors on both targets.
