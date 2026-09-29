# `.toList()` and empty-literal self-tests assert the stdlib `List`; `[]` no longer satisfies a user `record List` (#7702)

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

## Empty list literal

"an empty list literal still satisfies a List[T] ctor field" had the same
problem, and it exposed a real checker bug. It ran under `parseCheck` with a
local `record List[T] { }`. `[]` infers as `slice[<error>]` with no element
to type it, and `argSatisfiesParam`'s empty-literal exemption accepted that
for any parameter type NAMED `List`. So the test passed without the stdlib
`List` in play, and a real program putting `[]` into a field of its own
`record List[Int]` compiled and then failed at runtime
(`Msil.Codegen: unimplemented List member access: tag`), because codegen
builds a stdlib collection for the literal. This is the same name-vs-id split
#7696 fixed for non-empty literals.

- `argSatisfiesParam` (`typechecker_exprs.l`) now matches the stdlib `List` by
  TypeId (`stdCollectionsListTypeId`) instead of by name. That program is now
  a compile-time `T0104`.
- The positive case runs with `stdCollectionsHostPackages()` and no local
  record, and asserts that the bare `List` is `Std.CollectionsHost`'s. Both
  acceptance paths for a ctor-field `[]` (`argSatisfiesParam` and
  `listLiteralArgSatisfiesParam`) are now id-based. Literals record no type in
  `callResultTypes`, so the id-based acceptance is what pins the type.
- New negative cases: `[]` into a user `record List[Int]` field is exactly one
  `T0104`. `["a", "b"]` into a stdlib `List[Int]` field is exactly one
  `T0104` (a ctor-field argument is inferred without an expected type, so the
  literal is `slice[String]`).

## Verification

`lyric test lyric-compiler/lyric/typechecker_self_test.l`: 614 ok, 0 not ok.
The new assertions were checked for vacuity in two ways. First, all three cases
were temporarily reverted to the old harness (bare `parseCheck` plus a local
`record List[T]`). Each old zero-diagnostic or diagnostic-count assertion still
passed or failed as before, and each new recorded-type assertion failed with an
empty recorded type. The negative case's `T0043` count was 0. Second, the
expected types were temporarily changed to `List[Long]`, and each case failed
and reported the real `List[Int]` or `List[String]`.

For the empty-literal case: with the previous compiler, the new user-record
negative case failed (0 diagnostics; `[]` was accepted). With the fix,
reverting the positive case to the old harness (`parseCheck` plus a local
`record List[T]`) makes it fail with one diagnostic instead of passing.
