# D363 - Primitive-receiver members, numeric conversions and dependency union cases record their callee (docs/70 phase 3a, #8613)

**Status:** shipped. Extends D361 (declared callees) and D362 (built-in names).

## Context

After D362 the `LYRIC_VERIFY_IR=1` census over the stdlib tests still listed, in
order, `Ok`/`Err`/`Some` and the other dependency union cases, the `String`
members (`contains`, `startsWith`, `substring`, ...), `toString`, and the numeric
conversions (`toInt`, `toByte`, ...). Each was typed by a route that bypassed
`builtinMember` or `recordCtorCalleeNode`.

## Decision

1. A member the checker types as a function on a primitive, slice or array
   receiver is a built-in (such a receiver has no fields, so it cannot be a
   function-typed field), and the universal `toString()` is a built-in on any
   non-user receiver. Both record `Receiver.member` in `builtinByNode`.
2. A numeric conversion (`x.toLong()`), which returns before the general call
   path, records its name where it returns.
3. A union case of a dependency has no resolver DefPath for its union, so
   `recordCtorCalleeNode` names it `package::Union::Case`, the key the resolver
   would intern. The expected-type construction path (`inferCaseCtorExpected`)
   records its callee too; it is the path `Ok(1)` takes where a result type is
   expected.
4. After this change the census over `lyric-stdlib/tests/*_tests.l` lists
   only function-value calls and method calls on interface and extern receivers.

## Not covered

Function values (`Callee.Indirect`), interface and extern members, the
instantiation, conversion and argument-order tables, and the expression builder.
