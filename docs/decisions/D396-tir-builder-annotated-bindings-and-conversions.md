# D396 - The builder's annotated bindings and derived conversions (docs/70 phase 3a, #8613)

**Status:** shipped (`convKindOf`, `convertValue`, `buildInit` in `build_expr.l`); extends D367 and D369.

## Context

An annotated `val`, `let` or `var` was an I0002 ("an annotated binding"), and the
builder knew one implicit conversion, numeric widening (`widenKind`), spelled out
separately in `coerceArg` and `coerceBranch`.

## Decision

1. `convKindOf(from, to)` derives the implicit conversion from the two `Ty`s
   alone: numeric widening, `Never` used as a value (`CvFromNever`), `T` used as
   `T?` (`CvLiftNullable`), a value of a refinement's underlying type checked
   into the refinement (`CvRangeCheck`), and a refined value used as its
   underlying type (`CvUnrefine`). `convertValue` wraps a value in the node,
   or returns it unchanged when the types are equal. `coerceArg` and
   `coerceBranch` use it; nothing is guessed.
2. An annotated binding resolves its annotation with the checker's
   `resolveType` (the function's generic context is kept in `BuildEnv.generics`,
   so `val y: T = x` names the enclosing parameter), converts the initializer
   to it and declares the local at the annotated type. `val`, `let` and `var`
   with an initializer are covered.
3. Not derived from types, so still counted: a distinct-type wrap or unwrap
   (needs the declaration to know the type is distinct), an interface upcast
   (needs the implements relation), host boxing and slice/list conversions.
   They get their own tables with the slices that need them.
