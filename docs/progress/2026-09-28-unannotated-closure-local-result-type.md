# A closure bound to an unannotated local returns its real result on .NET (#7711)

On `--target dotnet`, calling a closure bound to a local with no type
annotation could return the boxed result's object reference as the value:

```
func c(base: in Int): Int {
  val inner = { -> base + 1 }
  inner()          // 67167040, not 8
}
```

The JVM was correct. The same happened after `return`, through an
unannotated `val r = inner()`, and through a nested closure; `Long`,
`Double` and `Option[Int]` results failed the same way.

MSIL lowers every closure to the uniform boxed `Func<object, ...>`, so a call
through one returns `object` and the call site must unbox it to the closure's
result type. Codegen took that type from the binding's annotation or, with
none, guessed it from the lambda body's trailing expression
(`inferLambdaBodyExprMsilType`). The guess sees only the lambda's own typed
parameters. A body that reads a captured local, such as `base + 1`, therefore
came out as unknown, and the call result was never unboxed. `val r: Int =
inner()` worked only because the annotated destination forced the conversion.

The checker already knows the closure's type. It now records it:

- The type checker adds `SymbolTable.localFuncTypeSites`, the checked
  function type of each unannotated `val`/`var`/`let` whose initializer is a
  function value, keyed by the initializer's span. Async function types,
  types that return `Never`, and types with no source spelling (a type
  parameter, an error) are not recorded.
- `Lyric.Mono.desugarCheckedFile` runs on exactly the file the checker saw.
  It writes each recorded type onto its binding as the annotation. From there,
  every later pass and both backends see the same thing as a hand-written
  `val inner: () -> Int = ...`: the lifted lambda is typed from it, and the
  call result is unboxed to the real type.

Verified by `closure_unannotated_result_self_test.l`, which runs on both
targets (`scripts/ci/compiler-self-tests-batch.sh` and
`scripts/ci/jvm-generics-self-tests-batch.sh`). Its 19 cases cover:

- a call in tail position, after `return`, and bound to an unannotated `val`
- nested closures and a captured closure called inside another
- `Long`, `Bool`, `Double`, `String`, record, `Option[Int]` and `Unit` results
- a closure that takes an argument, and a reassigned `var`
- a closure passed as a parameter or returned from a function
- a bare function value, and a closure chosen by `if`

Before the fix, the tail, return, bound, nested, `Long`, `Double` and
`Option[Int]` cases fail on dotnet.
