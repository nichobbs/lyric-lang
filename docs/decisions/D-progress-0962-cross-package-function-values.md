# D-progress-962 — Another package's function used as a value (#7250)

**Status:** shipped

## Problem

A top-level function could be passed as a value only when it was declared in
the same file (#5362, #6393). Any other package's function failed at compile
time, whatever the spelling:

- bare after `import Pkg.{f}`: MSIL T0115 (no forwarding thunk outside the
  file); the JVM happened to work;
- `Other.f` (collapsed to a full path by the alias rewriter) and the full
  path `Pkg.Other.f` (left as a member chain, since the rewriter only
  collapses call callees): MSIL T0115, JVM J008 on the root segment.

The type checker typed a qualified function path as an error type with no
diagnostic, and a bare value read `sigs`, whose first-registered entry could
be a same-named function from a package that is not even imported
(`Std.Xml.findAll` under `import Priv.Other.{findAll}`).

## Decision

- **Resolution.** A bare function value resolves through the scope-aware
  symbol table: the function the name denotes here, the one a call would
  bind. A qualified value (`Pkg.f`, or a full path written as a member chain
  whose root is not a local) resolves against the named package. When
  several packages end in the qualifier (`Lib.Bar`, `Other.Bar`), the ones
  in scope win; with none in scope every match stays, as unimported names
  resolve elsewhere (#6703). Several same-named functions left after that are
  T0123, bare or qualified, since a value cannot pick an overload. A
  function the forwarding lambda cannot stand for (generic, `async`, a
  non-`in` parameter, or a parameter type not nameable at the use site) is
  T0128 rather than a bare path left for the backend. The lambda's parameter
  and result types use a type's bare name only when that name denotes the
  same type at the use site; otherwise they are qualified by the type's
  package. An extern type (codegen resolves it by its bare name) or a type
  with no package cannot be qualified, so when its bare name means something
  else at the use site the function is unrepresentable (T0128) (#7371).
- **Lowering.** The type checker records each reference to another
  package's function that is not a call callee (`FuncRefSite`: the
  function's package path and name, and its parameter types rendered as
  source, a user type qualified by its declaring package).
  `Lyric.Mono.desugarCheckedFile`, run straight after type checking, replaces
  it with `{ p0: T0, ... -> Pkg.f(p0, ...) }`. Both backends already lower a
  typed lambda and a qualified call, so nothing backend-specific is added.
- **Inference.** The site also records the function's result type. The
  pipeline hands mono each desugared lambda's function type
  (`monoFileWithLambdaTypes`), so a generic call or record built from one
  (`Program(update = Logic.update, ...)` with no annotation) infers its type
  arguments instead of defaulting them to `Object`.
- **Scope.** Only a function such a lambda can stand for: non-generic,
  synchronous, every parameter `in`. Same-package references keep their
  existing per-backend lowering.

## Verification

`emitter_project_self_test.l` (EPFv) passes another package's functions as
record fields and a local on MSIL and the JVM, spelled bare, as `Other.f` and
by full path, with `Int`/`Long` parameters and a parameter of a type declared
in that package, and builds an unannotated generic record from one.
