# D-progress-980 — `PersistentList[T]` is a cons list; `PersistentMap` stays an association list (#7280)

**Status:** shipped

## Context

`Std.Collections.Persistent` represented a persistent list as a bare
`slice[T]` (#684). Every derive operation (`plistCons`, `plistTail`,
`plistInsert`, `plistDelete`) copied the whole slice, so building an n-element
list by consing, or walking it with repeated `plistTail`, was O(n²). The
persistent map is an association list, `slice[MapEntry[K, V]]`, keyed by a
caller-supplied equality predicate.

## Decision

**List.** `PersistentList[T]` is a nominal union:
`PLNil | PLCons(head: T, tail: PersistentList[T], size: Int)`. Each node
caches the length of the list it heads.

- `plistCons`, `plistHead`, `plistTail`, `plistLength` and `plistIsEmpty`
  are O(1). A derived list shares the part it keeps.
- `plistLookup`, `plistInsert` and `plistDelete` are O(index): they copy only
  the nodes before the index.
- `plistToList` and `plistFromList` are O(n).
- `plistEmpty[T]()` names the empty list.

This is a breaking change to an `@experimental` API with no callers outside
its tests. Indexed lookup gives up its former O(1) for O(index); a persistent
list is for sharing and sequential access, and `slice[T]` remains the
indexed type.

**Map.** `PersistentMap[K, V]` keeps its association-list representation.
With only an equality predicate, every lookup, insert and delete is an O(n)
scan whatever the structure. An O(log n) HAMT or balanced tree needs a hash or
ordering constraint on `K`, which the language cannot express yet (no generic
`Eq`/`Ord`/`Hash` interface). It is revisited when that lands.

**Bundling.** Under D111 every `Std.*` type lives in `Lyric.Stdlib.dll`, and
`Std.Collections.Persistent` was never in the bundle manifest. That was
harmless while it declared no types, but it does now. It is appended to
`lyric-stdlib/lyric.full.toml`, last, so earlier packages' token indices are
unchanged.

## Compiler fixes it needed

The cons node is the first stdlib generic type whose field nests the type's
own parameter across an assembly boundary. Four gaps surfaced and are fixed:

- **MSIL field references.** The stdlib union-case and record registrations
  (`registerStdlibTypeItemMembers`, `registerStdlibRecordLikeType`) lowered a
  field like `tail: PersistentList[T]` or `prefix: List[T]` generics-blind, to
  `PersistentList<object>`. The FieldRef then never bound
  (`MissingFieldException`). They now use `typeExprToMsilG`, as the
  restored-package path already did.
- **MSIL generic constructors.** `buildGenericCaseCtorTok` rebuilt a stdlib
  generic type's ctor signature as `!n` or `object` per field. It now uses the
  open parameter list the registration records in `genericCtorParams`. Its
  deferred `MNewobjGenericCase` also encodes that signature context-aware, so
  `List<!0>` is not flattened to `object`.
- **Monomorphizer.** A generic call passed as an argument to another generic,
  such as `plistCons(1, plistEmpty())`, had no expected type, so it was
  specialised at `Object`, which crashes on MSIL. `markArgsExpectedMono` now
  binds the outer callee's type parameters from its other arguments and marks
  such generic-call arguments with the resulting concrete parameter type. Only
  generic-call arguments are marked, so the widening rules for other arguments
  are untouched.
- **Native.** Instantiating a self-referential generic union or record
  re-entered itself while lowering its fields, overflowing the compiler's
  stack. The instantiation now registers a stub first, as the non-generic
  registration does.

One gap is left, tracked as #7413. On native, a zero-argument generic call
cannot take its type argument from a user-generic return context, so
`collections_persistent_tests.l` does not run on native yet. The module has
never compiled on native.
