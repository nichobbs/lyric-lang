# D565 - Record copies, catch bindings, untyped tails and explicit type arguments build (docs/70 phase 3a, #8613)

**Status:** shipped; extends D364, D389, D560 and D564.

## Context

Six more things the checker accepts left bodies unbuilt in the TIR census: a record `.copy(...)` (the
checker records a copy site and no callee), a `catch` that binds the exception, the tail of a lambda,
`if` branch or `match` arm that is a bare `None`, `[]` or a union case whose type arguments only the
context fixes (the checker leaves such a node untyped), the built-in reads `buffer.length` and
`exception.message`, a function body ending in a `scope { ... return ... }`, and a call under explicit
type arguments to a generic whose result type does not mention the parameter (`isNone[Int](x)`): the
checker recorded the instantiation only for a plain-path callee, so the builder fell back to solving the
parameters from the result type and lost `T`.

## Decision

- `XCopy(base, updates)` with `TFieldUpdate(field, value)`: a record copy, of the base's type. The base is
  evaluated once, before the updates, which run in source order. The verifier checks the base's type, that
  each updated field exists at its index and that each value has the field's type at the base's
  instantiation (`copy-type`, `copy-field-type`).
- A catch binding is a local of type `TException`; `exception.message` is the built-in read
  `Exception.message`, and `buffer.length` is `buffer.length`.
- The tail of a lambda body, `if` branch or `match` arm takes the type of its position when the checker
  left it untyped (`settled`, as an argument hole takes its parameter's type).
- A block with no tail whose last statement is `return`, `throw` or a `scope` that ends in one never
  completes, so it fits any type.
- The checker records the explicit type arguments of a call as its instantiation
  (`genericArgsByNode`) in `recordExplicitTypeArgCall`.
- `distinctUnderlyingOf` and `fieldsOfRecordInstantiated` are `pub` for the builder.

## Measured

`scripts/ci/tir-census.sh` over the 98 programs, on top of D564: bodies built 1056 -> 1079 of 1165,
I0003 0. `a try statement with a catch binding` 6 -> 0, `a member access that is not a record field`
6 -> 0, `a call the checker did not resolve` 11 -> 10, `a branch conversion` 6 -> 5, `a name that is not a
local` 30 -> 27. What is left of the cascade is mostly a pattern binding of a generic union field the
checker types as an error inside a generic function (`case Good(v) -> f(v)` in a generic body).
