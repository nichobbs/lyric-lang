# A lambda's own parameter captured by an inner lambda; calls through an element of a module-level `val` (#8317, #8283)

Two bugs in calls through function values.  The first was dotnet-only.  The
second miscompiled on dotnet, failed to compile on the JVM (J008) and on
native (N0007).

## A captured lambda parameter is unboxed into its closure field (#8317)

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

The capture store now narrows a parameter of the enclosing lambda exactly as
a read of it does (`castObjectToMsil`: `unbox.any` for a value type,
`castclass` for a reference type).  A field erased to `object` because its
type names an enclosing type parameter (#7695) still takes the boxed value as
it is.  The JVM and native backends were already correct.

## Calls through an element of a module-level `val` (#8283)

The type checker records the callee type of every call through a function
value (`funcValueCallSites`), and `Lyric.Mono` calls such a callee through a
local annotated with that type, so every backend knows the call's result type
(#7716).  `calleeIsFuncValue` accepted a callee that was a local or an index
into a local (`fs[0](x)`), but not a module-level `val` or an index into one
(`fns[1](3, 4)`).  The call's result was then untyped:

- dotnet invoked it through the uniform `Func` and left the result as
  `object`.  `moduleLambdas[1]("x") + moduleLambdas[0]("y")` was lowered as a
  numeric `add` of two object references (ilverify: ExpectedNumericType); the
  test program died with a segmentation fault.  The issue's other shape, a `?`
  in the arguments throwing `InvalidProgramException`, reproduces on a
  2026-09-27 build but no longer on `main` before this change.
- The JVM rejected the same `+` at compile time (J008, operands erased to
  `Object`).
- native read `fns[1]` as explicit type arguments on a function named `fns`
  and failed on the `1` (N0007).

The type checker now treats a bare or package-qualified name that resolves to
a module-level `val` (and no local shadows) as a function value, so these
calls are recorded and desugared like a local's.  Separately, native lowered
an indexed callee as a generic function's type arguments whenever its head
was a name; it now does so only when the name is a generic function of that
arity, and otherwise calls the element as a function value.  A callee that is
any other expression (`mk()()`, `(if c { f } else { g })()`) also lowers as a
function value instead of failing with "indirect calls are not yet
supported".  The value is held for the call, so the arguments cannot release
it.  This covers the calls the type checker leaves as written, such as a
`Unit`-returning element of a module-level `List`.

## Native closures capture names read only in a `for`, `loop`, `defer` or `scope`

Wiring `closure_correctness_self_test.l` into the native lane showed that
native's free-variable walk over a lambda body skipped `for`, `loop`, `defer`,
`scope`, `throw` and `invariant` statements.  A lambda that read a captured
name only inside one, such as `{ -> for x in xs { sink(x) } }`, failed with
"unknown name 'xs'" (N0007).  The walk now visits them, with a `for`
pattern's and a named `scope`'s bindings bound only in the body.

## Tests

- `closure_correctness_self_test.l`: curried `Int` lambdas and a reused
  partial application, an inner closure capturing the enclosing lambda's
  parameter (the issue's `runIt` shape), three levels, `Long`/`Double`/`Bool`/
  `String` parameters, a record parameter, a `List` of curried functions, a
  captured parameter beside a mutated `var`, and a curried `Unit`-returning
  lambda called in place.  It now also runs on native (the `var`-mutation and
  `assertPanics` cases are `@cfg(not(target = "native"))`, #7891 and D-N-003)
  and is verified by `scripts/ilverify-selfhosted.sh`.
- `slice_func_elem_self_test.l` (dotnet, JVM, native, ilverify): elements of
  module-level `List` and `slice` values of function type called in place, at
  a literal and a variable index, with `String` and `Long` results, with `?` in
  the arguments (both `Ok` and `Err`, and in tail position), `Unit`-returning
  elements, and a module-level `List` passed to a generic function.
