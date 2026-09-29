# Type annotations naming the enclosing type's parameter inside closures and tuple patterns (#7705)

#7695 made a body-local annotation in a generic record's method (`var x: T`
in a `Box[T]` method) resolve `T` the way the method's own signature does. Two
annotation sites still resolved `T` without the method's type parameters, and
both reproduced:

- **An annotation inside a closure body.** The closure is lowered as a
  separate function whose context never received the enclosing method's type
  parameters. On `--target jvm` the fresh `FuncCtx` of a lambda's `invoke`
  (and of a spawned expression's `call`) had empty `typeParams`, so
  `val z: T = …`, a no-initialiser `var z: T` or a `List[T]` local inside the
  closure named the nonexistent class `<pkg>/T` — `NoClassDefFoundError` the
  first time the closure ran, for every instantiation. `inheritTypeParams`
  (`06_items.l`) now copies them into both closure-body contexts. On
  `--target dotnet` the lifted `__lambda_*` is a static method of the
  non-generic package class, so `T` has no `!0` there and must erase to
  `object`; its `lambdaGenerics` entry carried only a generic *function's*
  own parameters, so `T` resolved to the nonexistent class `<pkg>.T`. That
  happened to encode as `object` in signatures (the unresolved-class fallback),
  so the IL ran and verified, but the tracked types were wrong (a `match` on an
  `Option[T]` local reported its scrutinee as `Option<<pkg>.T>`). The entry
  now also lists the enclosing type's own parameters
  (`FuncCtx.reifiedGenerics`), which erase through the generic-function path.
- **A tuple-pattern annotation**, `val (p, q): (T, T) = (self.value, other)`.
  On jvm, `lowerLocalPatBind`'s `PTuple` arm resolved each element through the
  typeParams-blind `typeExprToJvmExtern` (the same `NoClassDefFoundError`); it
  now uses `localAnnotatedJvmType`, the resolution a plain annotated binding
  uses. On dotnet, `typeExprToMsilG` had no tuple arm, so the elements
  resolved generics-blind: each destructured element was `castclass`ed to
  `<pkg>.T`, which the lowering dropped with W0003, and an `Int` element was
  read back as a raw object pointer (`Box[Int].second(2)` returned
  `1275121784`; ilverify: `StackUnexpected … found ref 'object' expected
  value 'T'`). The new `TTuple` arm resolves each element through
  `typeExprToMsilG`, so a `T` element is `!0` and is unboxed with
  `unbox.any !0`.

The third site the issue listed, a top-level generic function's body
annotation on jvm (`lowerFuncScoped` never threads `fnElemTps` into
`FuncCtx.typeParams`), does not reproduce: `Lyric.Mono` specialises every
generic function before codegen. Probes covering a single file, a generic
function with no call site, a return-only type parameter
(`val a: List[Int] = empty()`), explicit type arguments (`empty[String]()`), a
function-typed parameter (`applyTwice(inc, 3)`) and a two-package project
(`ProbeLib.keep[T]` called from `ProbeApp`) all emitted only specialised
copies (`empty__Int`, `applyTwice__Int`, `keep__Int`, …) with no reference to
a `…/T` class, and the generic originals are not emitted at all; so the path
is left as is.

## Verification

`generic_method_body_typevar_self_test.l` gains `closureLocals` (a
no-initialiser `var z: T` and a `List[T]` local inside a closure) and
`tupleFirst`/`tupleSecond` (`val (p, q): (T, T)`), each instantiated with
`Int`, `String` and a record. Before the fix, standalone probes of the same
shapes failed on jvm for every instantiation (`NoClassDefFoundError`) and, on
dotnet, returned a garbage value for the `Int` tuple case with 2 ilverify
errors. After: the test passes 22/22 on both targets.
