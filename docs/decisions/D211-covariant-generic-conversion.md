# D211 - A covariant generic value is converted into the declared instantiation

**Status:** accepted, implemented (#7774). Decided by the repo owner 2026-10-23.

## Context

`typeAssignable` accepts a value of `Result[English, String]` where a
`Result[Greeter, String]` is declared, `English` implementing `Greeter`: the
type arguments of a generic type are covariant. On dotnet and native the two
are different types at run time, with no case class in common, so the caller's
`match` found none of the declared type's cases ("match not exhaustive",
the #3502 failure class); the JVM erases type arguments and worked. The
constructor case, `Ok(value = English(...))`, was fixed by building the value at
the declared instantiation (#7752), but a value that already existed still went
through the covariant path. The covariance was also accepted only at a `return`
and a tail expression: an argument, an annotated binding, an assignment or a
field were rejected (T0043, T0060, T0063, T0104), and a union-case field was not
checked at all, so the same program compiled and failed at run time.

## Decision

Keep covariance, and convert the value where it flows into the place:

- Covariance holds at a `return`, a function's tail expression, an argument
  (parameter, constructor field, union-case field, call through a function
  value), an annotated `val`/`var`/`let` binding and an assignment, and
  through nested generic arguments (`List[Result[English, String]]`).
- At each such flow the type checker records the site
  (`SymbolTable.covariantSites`) and synthesizes a conversion function for the
  pair of types (`covariantHelpers`): a `match` over the union's cases that
  rebuilds the case at the target instantiation, a record rebuilt field by
  field, or a new `List` of converted elements, each field or element converted
  in turn when its own type differs. A recursive type converts through
  itself. `Lyric.Pipeline.applyCovariantSites` wraps the value in a call of
  the function for a target whose instantiations are distinct runtime types
  (MSIL and native, `MiddleEndOptions.bindListLiteralTypes`); the JVM erases
  type arguments, shares the value and applies nothing.
- A value that already has the declared type is not converted.
- Only types that can be rebuilt are covariant: a union, a record without a
  `var` field, and the stdlib `List`. Any other generic type (a `Map`, a `Set`,
  a record with a `var` field, an opaque or protected type) is invariant in its
  type arguments, which `typeAssignable` now enforces for every check that
  used to accept it and fail at run time on dotnet.

## Consequences

- A `List` converted this way is a copy: a write through the declared view is
  not seen through the original on dotnet and native. On the JVM the value is
  shared. Code that needs the original to see the writes keeps the element
  type.
- A flow inside a generic function between types that mention a type parameter
  is accepted unconverted: the instantiation is not known until the function
  is specialised.
- Tests: `covariant_conversion_self_test.l`, on dotnet, the JVM and native.
