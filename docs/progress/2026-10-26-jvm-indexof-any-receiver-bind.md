# JVM: `case Some(i)` against `.indexOf` binds an Int for any String receiver (#8591)

On `--target jvm`, in a file importing `Std.String`, `match e.indexOf(x) {
case Some(i) -> ... }` (and `.lastIndexOf`) left `i` an erased `Object`
whenever `e` was not a local, parameter or field: a string literal, an
interpolation, a concatenation, or a call result. A typed use such as
`s.substring(i)` then failed J008 at compile time. dotnet was unaffected.

`lowerMethodCall` already routed those calls through `Std.String`'s
`Option[Int]` function from the lowered receiver type, but
`scrutineeGenericArgs` had to rediscover that from the receiver expression,
and `receiverClassOf` only types locals and fields. The call site now records
its result instantiation in `FuncCtx.callSiteRetGenericArgs`, keyed by
`methodCallSiteKey`, and `scrutineeGenericArgs` reads it back, so the bind and
the call cannot disagree.

`enum_closure_pattern_bind_self_test.l` gains six cases (interpolated,
concatenated, method-call, function-call and local-bound receivers, plus the
`None` path) and now runs on JVM in CI as well as dotnet; 9/9 on both.
