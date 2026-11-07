# D345 - A dot-named overload is chosen by argument type, and the backends lower the one picked (docs/70 phase 2d, #8880)

**Status:** shipped for a call `Type.f(args)` to a dot-named function.

## Context

Two dot-named overloads can both take a call's arguments by count when each
has defaulted parameters:

    func Seed.base(x: in String, y: in Int = 0): Int { 100 + y }
    func Seed.base(x: in Int, y: in Int = 0, z: in Int = 0): Int { x + y + z }
    Seed.base(1)

`dotSigInPackage` took the first by count (the one leaving the fewest
parameters to their defaults) without looking at the argument types, so the
checker rejected the call (T0043). Choosing by type in the checker alone made
it accept the program and both backends then miscompiled it: they found the
callee by name and the call's argument count, never by the declaration the
checker resolved.

## Decision

1. `dotSigInPackage` takes the argument types: among the declarations that take
   the call's argument count, those whose parameters accept the types answer
   (the one leaving the fewest defaults first); when none does, the call is
   reported against the first by count, as before (T0042/T0043).
2. The checker records the site of a call written as the path `Type.f` as it
   does a member call (`calleeSites`, D336), under the dot-named function's
   DefPath.
3. The JVM, MSIL and native backends lower the declaration the site names,
   keyed by that declaration's own parameter count read from its DefPath, not
   by the arguments written; a dot-named call lowered as a static call binds
   its site under either the path key or the member-expression key.

## Consequences

- `emitter_project_self_test.l` runs the program above on MSIL and JVM, and
  `llvm_project_self_test.l` on native (ASan):
  `Seed.base(1)` is `1` and `Seed.base("a", 5)` is `105`.
- Two overloads with the same parameter count still cannot be told apart by the
  backends' `@count` keys; the checker records no site for them, as before.
