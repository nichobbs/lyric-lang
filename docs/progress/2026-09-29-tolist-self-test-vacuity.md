# `.toList()` type-checker self-tests assert the resolved stdlib `List` (#7702)

The `typechecker_self_test.l` case ".toList() bridges a slice value into a
List[T] parameter" ran under the bare `parseCheck` harness with a local
`record List[T] { }` and no `Std.CollectionsHost` in scope. `.toList()`
resolves its result through `stdCollectionsListTypeId`, which looks `List` up
in `Std.CollectionsHost` by package, so without that package the call's type
degraded to `TyError`, which every parameter accepts. The zero-diagnostic
assertion held whether or not `.toList()` resolved at all.

## Changes

- The case now runs with the stdlib collection package in scope
  (`checkWithImportedPackages(..., stdCollectionsHostPackages())`) and asserts
  the argument's recorded type. A new `recordedCallType` helper reads the type
  the checker stored for the call in `SymbolTable.callResultTypes`; a call
  whose result degrades to `TyError` stores nothing. `bareTypeOrigin` confirms
  the bare `List` it names is `Std.CollectionsHost`'s, which pins the recorded
  type to the stdlib `List` by identity: `callResultTypes` spells a type by its
  bare name only when that name resolves to the same type id.
- New negative case: `slice[String].toList()` passed to a `List[Int]`
  parameter must produce exactly one `T0043`, and its recorded type must be
  `List[String]`.
- "slice.toList() type-checks cleanly with no shadowing type in scope (#7665)"
  already had the stdlib package in scope but asserted only a zero diagnostic
  count. It now also asserts the recorded `List[Int]` type and its
  `Std.CollectionsHost` origin. The file has no `.toArray()` cases.

## Verification

`lyric test lyric-compiler/lyric/typechecker_self_test.l`: 612 ok, 0 not ok.
The new assertions were checked for vacuity in two ways. First, all three cases
were temporarily reverted to the old harness (bare `parseCheck` plus a local
`record List[T]`). Each old zero-diagnostic or diagnostic-count assertion still
passed or failed as before, and each new recorded-type assertion failed with an
empty recorded type. The negative case's `T0043` count was 0. Second, the
expected types were temporarily changed to `List[Long]`, and each case failed
and reported the real `List[Int]` or `List[String]`.
