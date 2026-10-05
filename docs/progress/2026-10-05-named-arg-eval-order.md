# Call arguments run left to right as written (#8158, D171)

A call now evaluates its receiver, then its arguments exactly once in source
order, then the omitted parameters' defaults, on every backend; the values are
passed in parameter order. Before, every backend evaluated the arguments in
parameter order, so `two(b = pos(x), a = zero(x))` ran `zero(x)` first.

- The type checker records each call whose arguments would run observably
  differently in parameter order (`SymbolTable.argOrderSites`, decided by
  `Lyric.Parser.callArgsNeedSourceOrder`), for free, generic, method,
  interface, dot-named, protected-type and restored callees and for record,
  exposed-record, opaque, protected-type and union-case constructors.
  `Lyric.Mono.desugarCheckedFile` evaluates those arguments (and a computed
  receiver) into locals in source order before the call, so MSIL, JVM and
  native all inherit it. A call already in parameter order, or whose reordered
  arguments are inert, is unchanged. Parameters record whether their default
  is inert (`ResolvedParam.defaultInert`).
- Backend pairing that disagreed with the checker's is fixed: a positional
  argument written after a named one (native free, generic and interface
  calls; JVM constructors), a non-generic union case's named fields (MSIL), a
  stdlib function's named arguments (MSIL), and a defaulted parameter followed
  by a required one (native). `exposed record` lowers natively as a record.
- Tests: `named_arg_eval_order_self_test.l` (23 cases, dotnet / JVM / native)
  logs each evaluation and checks its order for every callee shape, mixed
  positional and named arguments, omitted defaults in the middle, nested calls,
  `?` and `await` arguments, and reordered calls under `and`, `if` and a
  `while` condition. `restored_default_args_self_test.l` adds a restored
  producer's function, constructor and method with default thunks, on dotnet
  and the JVM. Wired into the compiler, JVM-generics and native self-test
  batches and the ILVerify sweep.
- Not covered: a type-qualified call (`T.m(x, args)`, `T.f(args)`) is not
  resolved by the type checker at all, so it is neither checked nor reordered.
