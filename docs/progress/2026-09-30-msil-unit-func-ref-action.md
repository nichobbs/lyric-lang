# MSIL: a `Unit` function reference is a real `System.Action` (#7783)

On dotnet every `(...) -> Unit` type is a `System.Action`/`Action`N`
(`typeExprToMsilCtx`), and a `Unit` lambda literal is built as one. A bare
top-level function used as a value (`run(bump)`, `Holder(act = bump)`,
`[bump, g]`) was not. `synthesizeBareFuncRefThunksMsil` forwarded it through
an `object`-returning `__lambda_fnref_<f>` thunk wrapped in a
`Func<..., object>` whatever the target returned. There were three
consequences:
- Passing that reference to an `Action` parameter, local or field was
  unverifiable IL. ILVerify reported 3 errors in
  `contract_generic_call_self_test` and 4 in
  `conversion_name_resolution_self_test` (`assertPanics(label, fn)`).
- `Action::Invoke` on the `Func` only worked because of how the runtime
  happens to dispatch it.
- Adding such a reference to a `List[() -> Unit]`, which is a genuine
  `List<Action>`, threw `ArrayTypeMismatchException` at run time. The JVM
  ran the same program correctly.

The thunk for a `Unit` target is now declared `Unit`, so
`lambdaReturnsVoidMsil` makes it a `void` method, and the construction site
builds `Action`/`Action`N` from it, as it already did for a `Unit` lambda
literal. Every producer that reaches an `Action` slot is now a real
`Action`. An `object`-typed callee holding an `Action` is no new case: `Unit`
lambda literals already produce one.

The new dual-target `unit_func_ref_action_self_test.l` covers a reference as
an argument, typed local, record field, returned value, `List` and `Map`
element, unannotated local, and a generic pass-through. Its `List` case fails
under the previous compiler. The test runs in both the compiler and
JVM-generics batches. It joins `scripts/ilverify-selfhosted.sh` phase 4
together with `contract_generic_call`, `conversion_name_resolution` and
`bare_func_ref`, which all verify clean now.
