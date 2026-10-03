# Restored dependencies: omitted defaulted arguments call compiled default thunks (#7827)

A callee in a package restored from its compiled DLL or JAR could not have a
defaulted argument left out. Confirmed on both targets before the fix: a
library `pub func f(x: in Int = 5)` consumed through a `[dependencies]` path
(dotnet) or a restored JAR (`restoredDllPaths`, JVM), called as `f()`, was
T0042 ("expected 1 argument(s), got 0"). The contract metadata's `repr`
strings rendered every parameter without its default (it did not even carry
`hasDefault`), and the same held for record methods, interface members and
`impl` methods.

Implemented as option (b) of the issue, recorded in D168 and docs/45 §5:

- `Lyric.ContractElaborator.synthesizeDefaultThunks` (new
  `contract_elaborator/default_thunks.l`) runs at the end of
  `Lyric.Pipeline.pipeCheckAndMono` and appends one `@no_aspect pub` nullary
  function per defaulted parameter of each public callable (free and
  dot-named functions, record and exposed-record methods, interface members,
  `impl` methods of public types), named by `Lyric.Parser.defaultThunkName`.
  Its body is the default as checked and desugared, so a widening default
  carries its conversion and a default may read private values. Parameters
  whose type names a type parameter or `Self` get none, and native builds
  synthesise none.
- `Lyric.ContractMeta` renders such a parameter as
  `x: in Int = <Pkg>.<thunk>()`, and an `impl` with one carries its method
  heads, so a concrete-typed consumer call takes the `impl` method's default.
  The format version is unchanged (additive, like D114's `bmode`).
- MSIL registers a restored function's parameter names and defaults
  (`registerRestoredFunc`, which also makes named arguments to restored
  functions pair), and a restored `impl`'s method parameters take precedence
  over the interface member's (`restoredImplMethodParams`). A restored
  dot-named function called method-style (`a.scaled(3)`) boxed its `Int`
  argument for an `int32` parameter and threw `InvalidProgramException`,
  with or without a default: `funcParamTypes` records a restored function's
  scalar parameters as `object` (#3920), so that call path now reads the
  declared types (`CodegenCtx.restoredFuncParamTypes`). The JVM needed
  no backend change: it registers the restored source's signatures like any
  other.
- T0161 does not compare a default known only as a thunk call.

`restored_default_args_self_test.l` (new; run by
`scripts/ci/restored-dependency-self-tests.sh`, which also runs the other
restored producer/consumer self-tests from one ci.yml step, keeping ci.yml
under its size ceiling) builds a producer and a consumer on both
targets and checks 14 calls: a free function (omitted, positional, named),
a default reading a private value, a widening `ULong` default from a `UInt`
value, a mixed positional/named call, a record method, a dot-named function,
an `impl` method on the concrete type and through the interface (library
and consumer side), an inherited interface default method, and a consumer's
own `impl` of the restored interface.
