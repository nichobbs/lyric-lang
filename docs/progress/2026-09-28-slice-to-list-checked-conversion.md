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
`Jvm.Codegen`'s dispatch (`04_calls.l`) — a still-open, tracked gap.

## Fix

- `typechecker_exprs.l`'s `inferMemberBase` gained a `TySlice`+`"toList"`
  case, ahead of `builtinMember`. Unlike `builtinMember`'s other slice
  methods (deliberately typed via structural `TySlice` specifically so they
  never need a real `TypeId`), `toList`'s result is a genuine `List[elem]`,
  which needs `List`'s actual `TypeId` to type-check wherever a `List[T]`
  is expected (a field, a `val` annotation, a call argument) —
  `builtinMember` has no `SymbolTable` to look that up with, so this case
  lives in `inferMemberBase` instead, which does have `tbl`. It resolves
  `List` through the exact same scope-visible name lookup
  (`symTableTryFindOne` + `symbolTypeIdOpt`) `resolveTypePath` uses for an
  ordinary `List[T]` type annotation — in practice this always succeeds,
  since `Lyric.Pipeline` preloads every stdlib package's signatures
  (D-progress-1011), so `List` resolves even without an explicit
  `Std.Collections` import (confirmed empirically).
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

## Docs

`docs/01-language-reference.md` §2.7 documents `.toList()` alongside
`.append`/`.concat`/`.slice`, noting the `--target jvm` gap.
