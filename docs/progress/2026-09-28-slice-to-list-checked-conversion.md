# `slice[T].toList()` ships on `--target dotnet`

Closes another gap catalogued in nichobbs/cloud-agents' `docs/lyric/gotchas.md`
alongside the `Int.toNat()` fix (D-progress, same day): `slice[T].toList()`
compiled but threw `unsupported method 'toList' on the receiver type` at
runtime, despite `lyric-stdlib/std/file.l`'s own module doc describing
`slice[T].toList()` / `List[T].toArray()` as the intended round-trip shuttle
— only the `List[T].toArray()` direction actually worked.

## Root cause

Two independent gaps, one per compiler phase:

- **Type checker**: `builtinMember` (`typechecker_exprs.l`) has no `TySlice`
  case for `toList` — a `slice[T]` receiver only gets `.length`/`.append`/
  `.concat`/`.slice`, so the call fell through to lenient/deferred dispatch
  and reached codegen unvalidated.
- **MSIL codegen**: `lowerMethodCallMsil`'s slice-op dispatch
  (`isSliceRecvMsil`) only recognized `append`/`concat`/`slice`; `toList`
  fell through to the generic unresolved-method runtime-throw stub.

`--target native` already implements this (`llvm_codegen.l`: `List` and
`slice` share one runtime representation there, so `toList`/`toArray` are
both a `lyric_list_copy`). `--target jvm` has no `toList` arm in
`Jvm.Codegen`'s dispatch (`04_calls.l`) — filed as #7662.

## Fix

- `typechecker_exprs.l`'s `inferMemberBase` gained a `TySlice`+`"toList"`
  case, ahead of `builtinMember`. Unlike `builtinMember`'s other slice
  methods (deliberately typed via structural `TySlice` specifically so they
  never need a real `TypeId`), `toList`'s result is a genuine `List[elem]`,
  which needs `List`'s actual `TypeId` to type-check wherever a `List[T]`
  is expected (a field, a `val` annotation, a call argument) —
  `builtinMember` has no `SymbolTable` to look that up with, so this case
  lives in `inferMemberBase` instead, which does have `tbl`.
  - **Review round 2 (#7665) caught a real hole in the first cut**: it
    resolved `List` via a bare, shadowable name lookup
    (`symTableTryFindOne(tbl, "List")`). A package declaring its own type
    named `List` shadows the stdlib one for that lookup, but
    `lowerSliceToListMsil` unconditionally constructs a genuine BCL
    `List<E>` at runtime regardless of what the checker resolved "List" to
    — and the shadowed case didn't even fail cleanly: the no-match fallback
    returns `TyError`, and `typeEquiv` treats `TyError` as equal to
    anything, so a `val` binding with ANY declared type silently accepted
    it and crashed with `InvalidCastException` at runtime instead of
    failing to compile. Confirmed both the hole and the fix by hand: a
    `record List { tag: Int }` in the same package as a `.toList()` call,
    assigned to a mismatched `val` — before the fix this built and crashed
    at runtime; after, it's a clean compile-time `T0060`.
  - Fixed by resolving `List` through its OWN owning package
    (`stdCollectionsListTypeId` → `symTableTryFindInPackage(tbl,
    "Std.CollectionsHost", "List")`) instead of a bare name, mirroring the
    established `isStdCoreMonadType` precedent this same file already uses
    for `Std.Core.Result`/`Option` ("a same-simple-name Result/Option union
    declared OUTSIDE Std.Core must never satisfy this check"). This also
    means `.toList()` no longer depends on `Lyric.Pipeline`'s stdlib
    preloading behavior being import-independent (an implementation detail
    the first cut happened to lean on) — it now resolves the same way
    regardless of the call site's own imports or any local shadow.
- `codegen.l` gained `lowerSliceToListMsil`, wired into
  `lowerMethodCallMsil` alongside `append`/`concat`/`slice`. It builds a
  genuine `MConcreteList(e)` (never the legacy erased `List<object>`
  fallback the other slice ops fall back to for element types with no
  array token) via `MListOp(LoCtor)`, then copies each element read
  through the existing `emitListCastRecv`/`emitListGetItem`/
  `castObjectToMsil` helpers (the same ones `emitSliceCopyLoopMsil` uses)
  into the new list via `MListOp(LoAdd)`. Because the type checker already
  requires `List` to resolve to a concrete type before this call
  type-checks at all, there is no legacy-fallback case to handle here.

The returned `List[T]` is a genuine copy: mutating it (`.add`, etc.) never
affects the source slice.

## Tests

New file `lyric-compiler/lyric/slice_to_list_self_test.l` (5 cases: `Byte`/
`Int`/`String` element types, an empty slice, and a `List.toArray().toList()`
round trip), `--target dotnet` only for the same reason
`int_to_nat_self_test.l` is (JVM rejects `.toList()` cleanly at BUILD time
instead: `error[J008]: method 'toList' cannot be called on a slice
receiver`). Wired into the same small "BuildInfo dotnet
batch" in `.github/workflows/ci.yml`. 5/5 pass. The existing
`slice_ops_self_test.l` suite (13/13, dual-target) re-verified unchanged.
Manually verified end-to-end against a freshly built `./bin/lyric` with a
standalone repro exercising `Byte`/`Int`/`String` slices, mutation
independence from the source slice, and (separately) that a call site with
no explicit `Std.Collections` import still type-checks and runs correctly.
Two new `typechecker_self_test.l` cases (583 total, up from 581) pin
#7665's fix directly: a `.toList()` call in a package that shadows `List`
with its own `record List` now produces exactly one `T0060` against a
mismatched `val` binding (previously zero diagnostics), and the ordinary
no-shadow case still type-checks with zero diagnostics.

## Docs

`docs/01-language-reference.md` §2.7 documents `.toList()` alongside
`.append`/`.concat`/`.slice`, noting the `--target jvm` gap.
