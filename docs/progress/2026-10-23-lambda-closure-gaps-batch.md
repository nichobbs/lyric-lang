# Lambda and closure gaps on dotnet, JVM and the checker (#8345, #8442, #8347, #8302, #8319, #8349)

One batch of lambda and closure fixes, covered by `lambda_gaps_batch_self_test.l` (dotnet, JVM and native, and
ilverify-gated on dotnet).

- **#8345.** A lambda's capture set no longer drops an enclosing name just because the body rebinds it somewhere
  (a `for x` variable, a `match` arm binding). The rebinding hides the capture only inside its own scope, so a
  read after the loop reads the capture. Both `lambdaCaptureNamesMsil` and `lambdaCaptureNamesJvm` now capture
  every free reference that names an enclosing slot; the bound-name collectors they used are deleted.
- **#8442.** A call through a function value passes the value's declared parameter types to its arguments as
  construction hints, as a call to a named function does. `f(Left(3))` against `(Either[Int, String]) -> ...`
  built an erased `Either_Left<int, object>` that the callee's `match` never matched ("match not exhaustive in
  __lambda_1"). The reported nested-lambda shape was only the visible part of that.
- **#8347.** A call with explicit type arguments (`boxer[Int]()`) now has the declared result type with the type
  parameters replaced. It was `TyError`, so `boxer[Int]()(9)().v` reached both backends with an unknown receiver
  type (a `TypeLoadException` on dotnet, J007 on the JVM) and `val s: String = idf[Int](3)` was accepted.
- **#8302.** A lambda in a parameter or record field default is moved into a private function
  (`Lyric.ContractElaborator.hoistLambdaDefaults`, run before lambda lifting on dotnet) and the default becomes a
  call to it. The dotnet backend lifts lambdas by position before lowering, so a default spliced into a call had
  no lifted body ("lambda token missing"). An unannotated parameter of such a lambda takes its type from the
  declared function type. A default whose type or value names a type parameter is left as it was.
- **#8319.** The generic-record function field case already worked on main. A call of a method that does not
  exist on a union (`Result`/`Option` have no `unwrap`) is now T0113 instead of reaching dotnet's
  "unsupported method" runtime stub.
- **#8349 (part).** A `slice[T]` lambda parameter, direct or captured, is converted to its `T[]` array at each
  typed read (a `List`-backed slice is copied), which is verifiable IL. A parameter or capture of an in-bundle
  generic type (`Box[Int]`, `Either[...]`) is still handed to typed consumers uncast: casting it throws for an
  erased construction. Tracked in #8349.
- **Already fixed on main, regression tests added:** #7152 (nested `return` in a lambda), #7219 (Unit-returning
  function values in typed slots), #7460 (closure writing a field of a captured record), #7880 (lambda record
  constructor argument), #8232 (`assert` in a generic function's lambda).
