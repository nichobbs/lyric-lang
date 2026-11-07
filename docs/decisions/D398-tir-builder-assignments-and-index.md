# D398 - The builder's assignments and index expressions (docs/70 phase 3a, #8613)

**Status:** shipped (`buildAssign`, `buildPlace`, `buildIndexRead` in `build_expr.l`); extends D397.

## Context

An assignment (`SAssign`/`EAssign`) and an index expression (`EIndex`) were
I0002. TIR makes both explicit: a `TPlace` (local, global, field, element) with
an `AssignKind`, and an `XIndex` with an `IndexKind`.

## Decision

1. `buildPlace` builds the target of an assignment: a local (`PlLocal`, the
   local's own type), a record field (`PlField`, D397's `fieldRefOf`) or an
   element (`PlIndex`). The place's type is the checker's recorded type of the
   target. `buildAssign` converts the value to the place's type as an argument
   is converted (D396) and emits `XAssign(place, kind, value)` as a `Unit`
   node; a statement assignment is a `TsExpr` of it. `AssEq` is `AkSet` and the
   compound operators map one to one.
2. `indexKindOf` gives the kind from the receiver's type: `TArray` is `IkArray`,
   `TSlice` `IkSlice`, `String` `IkString`; the stdlib `List` and `Map` are host
   types whose names differ per target, so they are told apart by the name the
   checker typed the receiver with (`List`, `Map`). The index is converted to
   `Int`, or to the map's key type, and only a single index is built.
3. Counted, not guessed: an assignment to a name that is not a local (a module
   level `var` does not exist, so this is a captured or unresolved name), through
   `self`, to a host member or to a non-record member; an index with several
   indices; a receiver that is none of the kinds above (a record's `index`
   method is `IkMethod`, a host indexer `IkHost`, both need their member tables).
