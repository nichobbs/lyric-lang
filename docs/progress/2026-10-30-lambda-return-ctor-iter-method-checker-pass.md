# Returned-lambda constructors, slice method syntax, nested lambda checking (#7679, #8471, #7879; #8349 not fixed)

Covered by `lambda_gaps_batch_self_test.l` (dotnet, JVM and native, ilverify-gated on dotnet) and
`typechecker_self_test.l`.

- **#7679.** A lambda literal that is the value a function returns (the implicit tail or a `return`) takes its
  parameter and result types from the function's declared `(P...) -> R` return type, as a literal bound to an
  annotated local already did (`seedReturnedLambdaFnTypesMsil`, reusing `registerLocalLambdaLiteralFnTypesMsil`).
  Before, the lifted body fell back to the uniform `Func` ABI's `object` result, so `Ok(value = None)` in the body
  built `Result_Ok<Option<byte[]>, object>`, which the caller's cast to `Result<..., string>` rejected. The
  function's declared return type expression is kept on `FuncCtx.declaredRetTe`; the tail form is armed with
  `retLambdaTailOffset`, consumed when the tail statement is reached (earlier statements' lambdas advance the
  ticker first). A generic function keeps the ABI's `object` (its own parameters erase in its lambdas). Only a
  literal that is itself the returned value is seeded: a lambda in a returned `if`/`match` branch is not.
- **#8471.** The function form `filter(xs, { u -> u > k })` already works on main on both targets (verified for
  `filter`, `map`, `fold`, `any`, `all`, `count`, `find`, `forEach`). The reported failure was the method form
  `xs.filter(...)`: a slice has no such method, the checker typed it as `TyError` and accepted it, the JVM
  rejected it (J008) and dotnet lowered it to a stub that throws when reached, never lowering its lambda
  argument, whose lifted body (with no recorded captures) then failed T0115. The checker now reports T0113 for a
  method call on a slice that names none of its built-in members, naming the function form when a plain
  function of that name exists.
- **#7879.** A call checked inside an enclosing lenient first pass of a deferred argument no longer runs its own
  lambda-argument second pass (`SymbolTable.lenientArgDepth`): the enclosing argument is re-checked against its
  expectation, which re-runs the inner call with both passes. Depth-d nesting was 2^d checks, now O(d^2).
  `typechecker_self_test.l` checks a depth-14 nest.
- **#8349 not fixed.** The slice half was fixed in D-progress batch of 2026-10-23. The in-bundle generic half
  (`Box[Int]`, `Either[Int, String]` lambda parameters reaching typed consumers) needs a runtime conversion from
  an erased construction (`Box<object>`) to the closed instantiation, per record and per union case; a cast is
  unsound because an erased construction can legitimately arrive (#7755), and the alternative, never building an
  erased construction, is the reified-generics work of docs/43 (Q-GEN-002). Left open.
