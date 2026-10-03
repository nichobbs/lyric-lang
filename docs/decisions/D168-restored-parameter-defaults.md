# D168 — A restored package's parameter defaults travel as compiled thunks

**Status:** accepted, implemented (#7827)

## Context

A call that leaves out a defaulted argument splices the parameter's default
at the call, for free functions (#7811) and methods (#7820). A consumer
knows a package restored from its compiled DLL or JAR only through the
package's contract metadata (docs/45), whose `repr` strings rendered each
parameter without its default. So `f()` for a restored
`pub func f(x: in Int = 5)` was T0042 ("expected 1 argument(s), got 0") on
both targets, and the same held for record methods, interface members and
`impl` methods.

#7827 offered two fixes: (a) serialise the checked, desugared default
expression and re-parse it on the consumer side, restricted to expressions
that resolve there; (b) compile the default in the library and have
consumers call it.

## Decision

1. **(b): each default becomes a thunk in the declaring package.** Once a
   package is type-checked and desugared (the end of
   `Lyric.Pipeline.pipeCheckAndMono`), `Lyric.ContractElaborator.
   synthesizeDefaultThunks` appends one public, `@no_aspect` function per
   defaulted parameter of each public callable: a free or dot-named
   function, a record or exposed-record method, an interface member
   (abstract or default), and an `impl` method of a public type. Its name is
   `Lyric.Parser.defaultThunkName` (`__lyric_default__[<owner>__]<callable>__<arity>__<param>`),
   it takes no arguments, returns the parameter's type, and its body is the
   default as checked and desugared, so a widening default already carries
   its conversion and a default may read the package's private values.

2. **The contract names the thunk.** `Lyric.ContractMeta` renders such a
   parameter as `x: in Int = <Pkg>.<thunk>()`, and the thunk itself is an
   ordinary exported `func`. A consumer re-parses the default like any other
   and splices the call; no default expression crosses the package boundary.
   An `impl` with such a parameter carries its method heads
   (`impl Shape for Sq { func area(self: in Sq, scale: in Int = ...): Int }`)
   rather than `impl Shape for Sq {}`.

3. **Whose default applies is unchanged by restoring.** As within a package
   (docs/01 §"Default arguments", #7820, #7828), a call takes the defaults of
   the declaration it statically resolves through: an interface-typed call
   gets the interface member's thunk, a call on the concrete type the `impl`
   method's (which is why the `impl` heads are carried), and a consumer's
   own `impl` of a restored interface declares its own defaults. T0155 does
   not compare a default it knows only as a thunk call.

4. **Not exported:** a parameter whose type names a type parameter of the
   callable or of its owner, or `Self` (a nullary thunk has nothing to bind
   the type parameter to), and the methods of a generic `impl`, whose head
   the contract renders without its type parameters. A consumer passes
   those arguments explicitly. A native build synthesises no thunks: it
   writes no contract, and `--shape module` exports every public function to
   JavaScript.

5. **No format version change.** A parameter default is already valid
   `repr` syntax and a thunk is an ordinary `func` decl: the change adds no
   field, and `formatVersion` stays as it is (the precedent is D114's
   `bmode`). A contract written before this change carries no defaults, so
   its consumers pass every argument, as they had to.

## Rationale

(a) would ship source across the package boundary and re-resolve it in the
consumer's scope: a default reading a private value of the library, or one
whose meaning depends on the library's imports, could not be carried, so it
needed a restriction rule and a diagnostic for every expression outside it,
and the widening the library's middle end applies would have to be redone in
the consumer. (b) evaluates the default exactly where it was checked, needs
no restriction, and matches how both hosts already model defaults behind a
call (`[Optional, DefaultParameterValue]` on .NET, Kotlin-style `$default`
synthetics on the JVM). Its cost is one public function per exported
default, and a static call where the source-level call would have evaluated
the expression inline.

Synthesising after the middle end, rather than before type checking, means
the default expression is checked once, at the parameter, so its
diagnostics keep naming the parameter default (#7811) and appear once.

## Consequences

- `docs/45` gains §5 (Parameter defaults) recording the format.
- `restored_default_args_self_test.l` builds a library and a consumer on
  both targets and checks a free function (positional, named and omitted),
  a default reading a private value, a widening default, a mixed call, a
  record method, a dot-named function, an interface member through the
  interface and through the concrete type, an inherited interface default
  method, and a consumer's own `impl` of the restored interface.
- Defaults whose type mentions a type parameter remain unavailable across a
  restored boundary; lifting that needs a thunk that can be instantiated at
  the call (a generic thunk the middle end specialises), tracked as a
  follow-up.
