# Open-binding detection keys on the resolved callee, not its name (#7801)

#7788 made an unannotated local initialized by an evidence-free construction
(`val xs = newList()`) take its type from its uses. `registerOpenBindingSite`
recognised the construction by its spelling: a call whose callee's last path
segment was `newList`, `newListWithCapacity` or `newMap`, or a path ending in
`None`. A package's own `func newList[T](): MyBag[T]`, or its own union's
`None` case, was therefore an open binding too, and a later `b.add(x)` could
annotate it with a type taken from an unrelated `add` signature — behaviour
that did not exist before #7788.

Fix: the `ECall` arm records, next to its generator-call bookkeeping
(#7771), whether the signature the call bound to is one of
`Std.CollectionsHost`'s `newList`/`newListWithCapacity`/`newMap`
(`SymbolTable.emptyCollectionCtorSites`, keyed by the call's span, cleared and
re-set on re-inference). A `None` initializer counts only when its inferred
type is the stdlib `Option` (`isStdCoreMonadType`, the type-identity check
#7665 established). `registerOpenBindingSite` consults those two facts
instead of the name.

Verified by three new `typechecker_self_test.l` cases against a fake stdlib
harness: a user `newList` and a user union's `None` are not open (both open
before the fix: 702/704 → 704/704), and the stdlib `newList`,
`newListWithCapacity`, `newMap` and `None` still are.
`unannotated_list_result_self_test.l` stays 11/11 on `--target dotnet` and
`--target jvm`. docs/01 §4.3 says the forms are recognised by resolution.
