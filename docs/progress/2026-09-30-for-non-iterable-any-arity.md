# `for` over a non-iterable type is T0126 at every arity (#7781)

`SFor` recognised the iterable types (slices, arrays, the stdlib `List[T]` and
`Map[K, V]`'s key/value collections, single-type-parameter extern types) and
rejected only one other shape with **T0126**: a Lyric-native generic with
exactly one type parameter (#6720), plus `String` (D-progress-1006). Every
other type — a record, union or enum with zero, two or more type parameters
(`record Pair[A, B]`, a user `record MapValueCollection[K, V]`), a primitive,
a tuple, a function value, the stdlib `Map[K, V]` itself — fell through to a
silent `TyError` loop element. That element is compatible with everything, so
every diagnostic involving the loop variable in the body disappeared, and the
program failed at runtime instead (`InvalidCastException` to `List<object>` on
dotnet, `IncompatibleClassChangeError: ... does not implement
java.lang.Iterable` on the JVM, for both a two-parameter record and a bare
`Map`).

Fix: the element typing moved into `forIterElemType`
(`typechecker_stmts.l`), which classifies the iterator's resolved type once.
The recognised iterables are unchanged; extern types other than the stdlib
`Map` stay accepted (their iteration is the host collection protocol's, which
codegen resolves), a single-type-parameter one still binding its type
argument. Everything else is exactly one T0126 at the iterator: the stdlib
`Map` names `mapKeys`/`mapValues`/`mapEntries`, a distinct type points at its
`.value`, a same-named user collection says it only shares the stdlib name
(#7737). The loop variable of a rejected `for` is `TyError`, as before. An
iterator whose own inference failed (already reported), a type parameter, and
`Self` stay lenient: their iterability is not decidable at the loop.

Verified by eleven new `typechecker_self_test.l` cases (a two- and a
three-parameter record, a user `MapValueCollection[K, V]`, a non-generic
record, a two-parameter union, an enum, a distinct type, `Int` and a tuple,
the stdlib `Map`, no second diagnostic for an unknown iterator, and a valid
slice loop still reporting a mistyped use of its element), 691/701 before
(the new assertions failing) and 701/701 after. docs/01 §4 (`for`) and the
book's T0126 row list the full rule.
