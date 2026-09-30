# Method calls splice omitted defaulted arguments (#7820)

A call to a record method, an `impl` method, an interface member, a
protected-type entry or a dot-named function that left out a defaulted
argument failed on both targets:

```lyric
record Acc {
  n: Int
  func add(self: in Acc, x: in Int = 5): Int { self.n + x }
}
func main(): Int { Acc(n = 1).add() }   // expected 6
```

`--target dotnet` threw `InvalidProgramException`, and `--target jvm`
failed to build with J008 (stackmap underflow). The type checker accepted
the call, but only the free-function call path in each backend spliced
defaults (`reorderFuncNamedArgs` + `fillPositionalFuncDefaults` on MSIL,
`reorderAndFillJvmArgs` on the JVM). Every method dispatch path lowered just
the arguments written at the call, so the callee was short an argument. The
same paths also passed named arguments in the order they were written rather
than in parameter order, and both backends' free-function paths left a
mixed positional-and-named call (`f(1, c = 3)`) unfilled.

**One pairing rule for every call.** `Lyric.Parser.argsWithDefaults` pairs
a call's arguments with the callee's parameters the way the type checker
does (`argIndicesInParamOrder`: named arguments to the parameters they name,
then positional arguments into the remaining parameters left to right). It
then fills each parameter still without an argument from its declared
default. Both backends route every call path through it:

- MSIL: `funcArgsWithDefaultsMsil` for free and dot-named functions
  (replacing the two older helpers, with a receiver skip for a
  `func T.m(self, …)` called as `r.m(…)`), and `methodArgsWithDefaultsMsil`
  for instance and interface dispatch, generic-record dispatch
  (`MCallvirtGeneric`), and a bare call to a sibling method. Each method's
  receiver-less declared parameters are recorded under its dispatch key
  (`CodegenCtx.methodParamDecls`, filled next to `methodParamModes`).
- JVM: `jvmArgsWithDefaults` over the `JvmFuncSig`'s names and defaults for
  the `<class>#<method>` instance and interface paths (including the
  `out`/`inout` holder path), the dot-named instance and static paths, and
  the existing free-function and bare-sibling paths.

**Converted defaults.** A default that widens (`x: in ULong = someUInt`) is
spliced in the converted form the declaring package's middle end produces
(#7811). On the JVM, `Jvm.Codegen.refreshMethodDefaultsJvm` now refreshes the
`<class>#<method>` signatures of record, exposed-record, protected, `impl`
and interface methods from the middle-ended file, as `refreshOwnDefaultsJvm`
already did for functions. `Lyric.Pipeline.pipeFileDeclaresDefaults` now
counts method parameter defaults, so another package's method defaults are
checked and desugared before the entry package is generated.

**Which default applies.** A call takes the defaults of the declaration it
statically resolves through: the interface member's for a call on an
interface-typed value, and the `impl` method's for a call on the concrete
type (docs/01 §"Default arguments"). The type checker used to list the
interface's members as candidates for a concrete-typed call alongside the
implementing method. When the `impl` method declared no default, it then
accepted `sq.area()` through the interface signature, which the backends
could not honour. `methodCandidatesFor` now drops an interface member the
type implements itself, so that call is T0042.

**T0042 for unpaired arguments.** The checker validated only the argument
count, so `f(b = 2)` for `f(a: Int, b: Int = 0)` and `f(1, q = 2)` passed. A
named argument naming no parameter (`no parameter named 'q'`) and a parameter
with no default left without an argument (`missing argument for parameter
'a', which has no default`) are now T0042 for functions and methods alike
(`reportUnpairedCallArgs`).

Tests: `method_default_args_self_test.l` (new, dual-target, 12 cases: record
methods positional/named/mixed, a widening `ULong` default, a default reading
a module value, bare and `self.` sibling calls, dot-named functions called
both ways, `impl` methods on the concrete type, interface calls, interface
default methods with overridden and inherited defaults, a generic record
method, a protected entry, a mixed free-function call). It runs in the
compiler and JVM-generics self-test batches and ilverify phase 4.
`msil_project_bridge_self_test.l` and `jvm_cross_package_collision_self_test.l`
each gain a cross-package case (record method, widening method default,
interface through both receivers). `typechecker_self_test.l` gains the T0042
and concrete-resolution cases.
