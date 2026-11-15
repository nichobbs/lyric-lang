# D477 - A qualified enum or union case read as a value is a reference the checker records (docs/70 §6.3, #8613)

**Status:** shipped.

## Context

`Lv.Trace` (an enum case, or a nullary union case, named through its type) is a member expression whose receiver is a type name, not a value. The checker typed it as the enum (`qualifiedEnumCaseType`) but recorded no reference for it, so the builder took it for a field read and tried to build the receiver `Lv`, which has no type: I0002 "the checker recorded no type for expression node" in every body that names a case this way (`lyric-logging`'s `trace`/`debug`/`info`/`warn`/`error`/`fatal`, the bulk of the ecosystem census's un-typed-expression bodies).

## Decision

The checker records the case under the member's `NodeId` (`refByNode`, `RkNullaryCase`) for a qualified enum case (`recordQualifiedEnumCaseRef`) and for a nullary qualified union case. The builder's `EMember` arm builds a member that has a recorded reference as the reference (`buildRefPath`: `XConstruct` of the case) and otherwise as a field read, so the receiver is never built.

## Not covered

A package-qualified case (`Pkg.Case`) already recorded its reference; a case with a payload is a constructor, built by its call.
