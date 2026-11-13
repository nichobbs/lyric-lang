# D461 - The checker records a stdlib collection's `clear()` as a built-in member (docs/70 phase 3a, #8613)

**Status:** shipped; extends D362.

## Context

The checker records a call of a stdlib `List`, `Map` or `Set` member as the built-in `List.add`, `Map.add`, ... (`builtinByNode`)
only when the member takes parameters it checks (`stdCollectionMemberParams`). `clear()` takes none, so it was left as a call
of a member of the extern host type (`externByNode`), which the builder resolves against the host's metadata: the host's
method is `Clear`, not `clear`, so the call was counted as "an extern call no host overload fits" (five bodies of the compiler's
own native backend).

## Decision

A zero-argument `clear()` on a stdlib collection (the receiver `stdCollectionMemberResult` types as `Unit` for it) is recorded
as the built-in `List.clear`, `Map.clear` or `Set.clear`, like the other members the backends lower by name. The call
builds as `XCall(Intrinsic(IoBuiltin(name)))` with the collection as its receiver. `typechecker_self_test.l` pins the three
records.
