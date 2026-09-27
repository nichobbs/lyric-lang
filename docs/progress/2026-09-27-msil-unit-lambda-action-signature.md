# MSIL: `Unit`-returning lambdas are `void` methods behind their `Action` (#7166, #7520)

A lambda whose destination is a `Unit`-returning function type now compiles
to verifiable IL on `--target dotnet`, and runs when the destination is a
BCL delegate slot. Two related defects are fixed.

**Delegate/method signature mismatch (#7166).** For a lambda bound to an
annotated `() -> Unit` local, or passed to an ordinary higher-order
function's `() -> Unit` / `(A) -> Unit` parameter, the construction site
built a `System.Action` delegate (it reads the real `Unit` return from
`lambdaRetTypes`, #5329). The lifted `__lambda_<i>` method's own signature
consulted only the `@externTarget` registry, so it still returned `object`.
The CLR does not check `ldftn object __lambda_N(...)` feeding `newobj
Action::.ctor`, but `ilverify` rejects it as `[DelegateCtor] Unrecognized
arguments for delegate .ctor`. It fired at every such call site, and in
`Std.ConsoleHost.startStdinRead` and `Std.ProcessPipedHost.ensureBackgroundRead`,
which failed PR #7520's `ilverify-required` gate. Both sites now share one
predicate, `lambdaReturnsVoidMsil`.

**`Func<object>` in an `Action` slot.** A lambda literal in any of these
positions was still built as `Func<object>`:

- a record field initializer for a field of type `() -> Unit`;
- the value returned from a function declared to return `() -> Unit`
  (tail expression or `return`);
- an element added to a `List[() -> Unit]`, or a value added to a
  `Map[K, () -> Unit]`.

`ilverify` reported `StackUnexpected`. At run time the value's type did not
implement `System.Action`, so `Task.Run(Action)` completed without running
it, and a typed list's backing array rejected it
(`ArrayTypeMismatchException`). These destinations now
mark the literal `Unit`-returning when the slot's MSIL type is
`System.Action` / `System.Action`N` with a matching arity
(`seedLambdaLiteralVoidRetMsil`). For a block tail, the mark is applied
only when lowering reaches that tail expression (`FuncCtx.voidLambdaTailOffset`),
after every earlier lambda in the body has taken its ticker slot. A chained
call on such a factory (`makeWork(s)()`) now dispatches on the callee's
static type (`invokeLoadedFuncValueMsil`), like a call through a local,
instead of always casting to `Func`.

Known gap: an *unannotated* local bound to a lambda (`val work = { -> ... }`)
has no declared function type for the MSIL backend to read, so it keeps the
uniform `Func<object>` shape.

New `lyric-compiler/lyric/extern_delegate_value_dotnet_self_test.l` (in
`scripts/ci/compiler-self-tests-batch.sh`) runs a closure through
`Task.Run(Action)` and through ordinary higher-order functions. It covers
each way the closure can arrive: a lambda literal, an annotated local
(including a `try`/`catch` body), a forwarded parameter, a record field, a
function's return value, and a typed `List`/`Map` element. It also checks
`Unit` and value returns. Its emitted DLL is `ilverify`-clean. `scripts/ilverify-selfhosted.sh` reports 0
IL-validity errors across 126 DLLs. The test is dotnet-only: the JVM has no
delegate bridging, since a function value is already a
`java.util.function` instance on every route.

`closure_correctness_self_test.l` and `closure_zero_overhead_self_test.l`
now have no `DelegateCtor` findings. `ilverify` still crashes (an internal
`InvalidCastException` in `ImportStoreElement`) on the methods that capture a
mutable `var`. The capture cell is allocated with `newarr System.Object`,
stored in an `object` local, and then written with `stelem Int32`. That
defect predates this change and is tracked with the `var`-capture bug #7460.
