# D383 - The checker records package-qualified and method calls whose type argument nothing fixes (docs/70 phase 3a, #8760)

**Status:** shipped. Step one of the remaining #8760 plan; follows D339, D381 and D382.

## Context

`noteUnsolvedCall` recorded an unsolved type argument only for a call through
a single-segment path. A package-qualified call (`Pkg.f(x)`, which the alias
rewriter turns into a multi-segment path) and a method or UFCS call
(`recv.f(x)`) were skipped, so only `Lyric.Mono`'s own T0224 covered the
qualified shape, and no check covered the method shape.

## Decision

- A multi-segment path callee is recorded under its last segment when the
  qualifier names the package the signature came from and its first segment
  is not a name in scope (`noteUnsolvedCall`).
- A method or UFCS call whose pick the method space resolved is recorded
  (`noteUnsolvedMethodCall`). A type parameter the receiver fixes is solved:
  through the first parameter of a dot-named function, and, for a method of a
  generic type, through the parameters the type itself declares
  (`genericBoundByReceiver`).
- The same fixes apply as for a bare call: the expected type, a recorded
  type-argument site, an open binding, and indeterminate arguments.

## Not in this change

A dot-named function called through its type name (`Box.conv(b)`) is still
not recorded. Mono's backstop is therefore not deleted here; that is the next
step, after a CI round with the rewriter still reporting.

## Tests

`typechecker_self_test.l`: the package-qualified cases (unfixed, written type
arguments, declared result type, a later argument) and the method cases (an
unfixed method type argument, a declared result type, a parameter the
receiver fixes), through `checkWithImportedPackages` after the alias rewriter.
