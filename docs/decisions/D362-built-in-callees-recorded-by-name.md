# D362 - Built-in functions and built-in members are recorded by name, beside `calleeByNode` (docs/70 phase 3a, #8613)

**Status:** shipped for `println`/`print`/`toString`-style built-in functions, for
the typed members of slices, arrays and primitives, and for the element-taking
members of the stdlib `List`, `Map` and `Set` (`add`, `contains`, `remove`, ...).

## Context

D361 keyed a call's callee by `NodeId` as a `SymbolId`. A built-in has no
declaration and so no `SymbolId`: TIR names it `Callee.Intrinsic(IoBuiltin(name))`
(docs/70 §6.2). The D361 census ranked these two routes (collection members,
then built-ins) as the largest uncovered classes after constructors.

## Decision

1. `SymbolTable.builtinByNode: Map[Int, String]` holds the built-in's name for a
   call's `NodeId`: `println` for a function, `List.add` or `slice.append` for a
   member, the receiver head (`dotNamedOwnerName`, or `slice`/`array`) joined to
   the member name. The name is the one the builder passes to `IoBuiltin`.
2. A call is covered when either table has it (`Lyric.Tir.Build.callCovered`).
3. A declared signature or method pick wins: `recordBuiltinCall` runs only when
   no direct signature resolved, and the collection route only when no method
   pick did, so a user function never reads as a built-in.
4. `calleeSites` and the backends are untouched.

## Not covered

Calls through function values, interface and extern members, the instantiation,
conversion and argument-order tables and the expression builder remain open.
The collection route is tested through the census on real code
(`LYRIC_VERIFY_IR=1`), because the self-test harness checks single files
without the stdlib; the self-test covers `println` and a slice member.
