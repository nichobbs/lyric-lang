# D356 - The extern and no-source-position exemptions of the unpinned-call rule are removed (docs/70 phase 3a, #8760)

**Status:** shipped. Step three of the remaining #8760 plan; follows D383 and D384.

## Context

D335 let three kinds of call keep the erased `Object` default for an unpinned
type argument instead of being the error T0224: an `@externTarget` generic, a
name the local scope binds, and a call without a source position. D384 made an
unpinned imported call Mono did not expect an internal M0002, so the
exemptions were the only way left for such a call to reach codegen unreported.

## Census

With both the extern and the no-position exemption removed from Mono, stage 2
(the compiler and the stdlib), the 85 library manifest builds (dotnet, JVM and
native), and the examples (36 manifests and the single-file programs on
dotnet) report no M0002. The one case found was two same-package calls of an
`@externTarget` generic in `lyric-stdlib/std/_kernel/http_server.l`
(`chunks = newConcurrentQueue()`), whose type argument the record field fixes.

## Decision

- The checker judges an `@externTarget` generic call like any other, including
  one of the package itself (`ResolvedSignature.hostBound`), so an unfixed one
  is T0224.
- When the expected type fixes a call's type arguments, the checker records
  that solution (`recordExpectedSolution`, at the end of the file, once the
  expected types are known) for the monomorphiser, which reads it through
  `fillCheckedTypeArgsMono`. Mono has no view of a record constructor's field
  types, which is why the extern calls needed it.
- Mono keeps one exemption, `callsFunctionValueMono`: a name the local
  environment binds is a function value, which has no type arguments to infer.
  The extern and no-position exemptions are deleted; a generated call is
  checked like user code and carries a position (D390-D393).

## Not in this change

A call without a source position is still not recorded by the checker (there
is nowhere to report it); if one is ever unpinned, Mono reports the internal
M0002. No such call exists in the census. `testdata/` does not exist in the
repository, and the JVM and native kernels of the examples were not built.

## Tests

`typechecker_self_test.l`: an extern generic call, imported and of the package
itself, unfixed (T0224), fixed by a written type argument, and fixed by a
constructor field with its solution recorded. `mono_self_test.l`: the
`@externTarget` case is no longer exempt.
