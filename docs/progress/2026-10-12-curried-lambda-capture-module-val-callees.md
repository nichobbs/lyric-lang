# A lambda's own parameter captured by an inner lambda; calls through module-level `val`s of function type (#8317, #8283)

Two bugs in calls through function values, with fixes on all three targets.

## A captured lambda parameter keeps its real type (#8317)

Under the uniform `Func<object, ..., object>` ABI a lifted lambda's parameters
arrive as `object`.  A read of one in the lambda's own body unboxes it to its
logical type (`boxedParamTypes`).  An inner lambda that captured one did not.
The closure-class field is typed with the parameter's logical type (`int32`
for an `Int`), but the capture store loaded the boxed reference from the
parameter slot and stored it into the field as it was.  A curried
`{ a: Int -> { b: Int -> a + b } }` then read the object reference as an
`Int`: `one(3)(4)` printed a large garbage number, ilverify reported
"found object, expected Int32", and an inner closure that logged its
enclosing lambda's `Int` parameter logged `s-1870636184` instead of `s1`.
`Long`, `Double`, `Bool`, `String` and record parameters were wrong in the
same way.

On dotnet the capture store now narrows a parameter of the enclosing lambda
exactly as a read of it does (`castObjectToMsil`: `unbox.any` for a value
type, `castclass` for a reference type).  A parameter whose type has no
verifiable narrowing from `object` (`boxedParamNarrowIsNoopMsil`: a slice,
which may be a `List`-backed construction, or an in-bundle generic such as
`Box[Int]`, which may be an erased one) is kept boxed: its closure field is
`object` (`lambdaObjectFieldCaps`, carried to a lambda that re-captures it),
and it is read as the parameter itself is.  A `match` on such a value keeps
its scrutinee in an `object` slot and tests it with `isinst`; a direct
`match` on a generic union parameter was already unverifiable before this
change (ilverify: expected `Either`2<int32,string>`).  A field erased to
`object` because its type names an enclosing type parameter (#7695) is
unchanged.

On the JVM a slice parameter arrived as `Object` and was never cast, so both a
direct read (`aaload` on an `Object`) and a capture (the closure constructor's
`Object[]` parameter) failed verification.  The lambda prologue now coerces
each parameter as any erased value reaching a slot of its type is
(`coerceArgToCtx`), which narrows or converts a slice.  Native was correct.

## Calls through module-level `val`s of function type (#8283)

The type checker records the callee type of every call through a function
value (`funcValueCallSites`), and `Lyric.Mono` calls such a callee through a
local annotated with that type, so every backend knows the call's result type
(#7716).  It recorded a local or an index into one (`fs[0](x)`) but not a
module-level `val`:

- An index into a bare module-level `val` (`fns[1](3, 4)`) was not recorded.
  dotnet left the result `object` and lowered
  `moduleLambdas[1]("x") + moduleLambdas[0]("y")` as a numeric `add` of two
  object references (ilverify: ExpectedNumericType; the program died with a
  segmentation fault), and the JVM rejected the same `+` (J008).
- A package-qualified `val` (`SelfQ.strs[1](x)`, `XP.Lib.strs[1](x)`,
  `XP.Lib.greet(x)`), the file's own package included, was typed as a member
  of the package and came out as an error type.  dotnet reported T0115 or
  T0123 or threw `NullReferenceException`, the JVM J002 or J008, native N0007.
- A module-level `val` named like an imported function (`isSome`, a
  `List[(Int) -> Bool]`, beside `Std.Core.isSome[T]`) was read as the function,
  so `isSome[0](5)` became an explicit type argument (T0123 on dotnet, a
  `VerifyError` on the JVM).

The type checker now resolves a bare or package-qualified path to a
module-level `val` (`moduleValSymbolOfSegs`) when no local shadows its root:
it is typed as the `val` wherever it is read (a member chain, a collapsed
qualified path, a call under an expected type) and is a function value when
called.  A `val` or `const` the current scope resolves a bare name to hides an
imported function of that name, as the package's own declarations hide its
imports.  `Lyric.Mono` no longer takes `name[i](...)` for explicit type
arguments when a local or a module-level `val` of that name is in scope.  The
issue's original `?` shape (`InvalidProgramException`) reproduces on a
2026-09-27 build but not on `main` before this change.

Native read `fns[1]` as explicit type arguments on a function named `fns` and
failed on the `1` (N0007).  It now does so only when the name is a generic
function of that arity and no local or module-level `val` of the current
package hides it, and calls the element as a function value otherwise.  A
callee that is any other expression (`mk()()`, `(if c { f } else { g })()`)
also lowers as a function value instead of failing with "indirect calls are not
yet supported"; the value is held for the call, so the arguments cannot
release it.  This covers the calls the type checker leaves as written, such as
a `Unit`-returning element.  A package-qualified `val` read through a member
chain (`SelfQ.strs`) resolves to the module value.

## Native closures capture names read only in a `for`, `loop`, `defer` or `scope`

Wiring `closure_correctness_self_test.l` into the native lane showed that
native's free-variable walk over a lambda body skipped `for`, `loop`, `defer`,
`scope`, `throw` and `invariant` statements.  A lambda that read a captured
name only inside one, such as `{ -> for x in xs { sink(x) } }`, failed with
"unknown name 'xs'" (N0007).  The walk now visits them, with a `for`
pattern's and a named `scope`'s bindings bound only in the body.

## Tests

- `closure_correctness_self_test.l` (dotnet, JVM, native, ilverify): curried
  `Int` lambdas and a reused partial application, an inner closure capturing
  the enclosing lambda's parameter (the issue's `runIt` shape), three levels,
  `Long`/`Double`/`Bool`/`String` parameters, a record parameter, a `List` of
  curried functions, a captured parameter beside a mutated `var`, a curried
  `Unit`-returning lambda called in place, a slice parameter read directly,
  captured and re-captured (including a `List`-backed literal argument), and
  a captured `CurryBox[Int]` and `CurryEither[Int, String]` matched in the
  inner lambda.  The `var`-mutation and `assertPanics` cases are
  `@cfg(not(target = "native"))` (#7891, D-N-003).
- `slice_func_elem_self_test.l` (dotnet, JVM, native, ilverify): elements of
  module-level `List` and `slice` values of function type called in place, at
  a literal and a variable index, with `String` and `Long` results, with `?` in
  the arguments (both `Ok` and `Err`, and in tail position), `Unit`-returning
  elements, a module-level `List` passed to a generic function, the same values
  named with the package (`Lyric.SliceFuncElemSelfTest.moduleFns[1](3, 4)`,
  `...moduleGreet("b")`), and a module-level and a local `val` hiding
  `Std.Core.isSome`/`isNone`.
- `scripts/ci/hoisted-callee-cross-package-e2e.sh` (dotnet, JVM, native): the
  sibling-package `pub val` list case now runs on dotnet too, and a new project
  calls the library's `pub val`s named with their package
  (`HcLib.fns[i](..., ok(4)?)`, `HcLib.strs[1]("x") + HcLib.strs[0]("y")`,
  `HcLib.greet("z")`) and a function-typed `pub val` bare (`greet("b")`).
