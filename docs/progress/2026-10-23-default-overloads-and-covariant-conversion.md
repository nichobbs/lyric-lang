# Default-argument overload resolution, and conversion of covariant generic values (#8355, #8077, #7774)

- **A call resolved through defaults binds the overload that fills the fewest
  defaults** (D208, #8355, #8077). The checker overwrote one `sigs[name]` slot,
  so `f(a)` over `f(x, y = 1)` and `f(x, y = 10, z = 100)` bound whichever was
  declared last, and dotnet then emitted an `InvalidProgramException`. Candidates
  are the declarations the call fits whose parameter types the arguments
  satisfy; a call supplying every parameter wins, a name only one declares
  narrows, the fewest defaults decides, and a tie that remains is **T0200**.
  `Lyric.Parser.callDefaultsFilled` / `fewestDefaultsCandidates` carry the
  shape of the rule; the checker (`pickByShape`, `resolveMethodCallPick`)
  decides and records the chosen declaration's parameter count in
  `methodCallArities`, which the MSIL, JVM and native backends and
  `Lyric.Mono` now read for free calls as they did for method calls. The mode
  check (V0002) and stability check (S0001) take every declaration a call fits
  as reachable, and the verifier resolves a call only when exactly one fits.
  Tests: `default_overload_self_test.l` (dotnet, JVM, native),
  `default_overload_diag_self_test.l`, and the updated `modechecker_self_test.l`
  and `verifier_self_test.l`.
- **A covariant generic value is converted into the declared instantiation**
  (D209, #7774). `Result[English, String]` returned, passed, bound, assigned or
  stored where `Result[Greeter, String]` is declared made the caller's `match`
  panic on dotnet. The checker records the flow and synthesizes a conversion
  function; MSIL and native apply it, the JVM shares the value. Covariance is
  now accepted at arguments, bindings, assignments and fields as well as returns
  and tails, and only for unions, records without a `var` field and `List`.
  Test: `covariant_conversion_self_test.l` (dotnet, JVM, native).
