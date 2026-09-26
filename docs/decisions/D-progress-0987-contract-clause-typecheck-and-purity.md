# D-progress-987 — Contract clauses are type-checked and purity-checked

**Status:** shipped

Closes the remaining items of #7228. D-progress-982 already made
quantifiers sound under negation, and D-progress-984 implemented `when:`
barriers.

## Problem

The type checker never visited `fn.contracts`. Elaboration turns the
clauses into asserts only after type checking, so an ill-typed clause either
passed silently or failed in codegen. `requires: x == "a"` on an `Int`
parameter compiled. `requires: x > nope` surfaced as a codegen T0115, not as
an unknown name.

Language reference §6.3 lets a contract call only `@pure` functions. The
only related check was the V0002 call-graph rule for `@proof_required`
code, so any function, I/O included, could be called from a
runtime-checked clause.

## Decision

- **T0132.** `checkFunctionBody` checks each clause in the function's own
  scope, after the parameters are bound. `EResult` falls back to the
  declared return type. `requires:`, `ensures:`, `when:` and loop
  `invariant:` must be `Bool`. A `decreases:` measure, which the parser does
  not yet produce for functions, must be an integer type.
  Unknown names and operator mismatches now get the ordinary type-checker
  diagnostics.
- **T0133.** While a clause is being checked the scope carries a contract
  marker. A call there that resolves to a Lyric signature, whether a direct
  function or a method pick, must have `isPure`. The check hooks the
  checker's own call resolution rather than re-resolving names, so
  overloads, UFCS and qualified calls are judged on the signature actually
  chosen. Operators, field reads and built-in members are not calls.
- **`@pure` is trusted, not verified.** It is a declaration. Verifying
  bodies (transitively, including host calls) is a separate and larger
  question, and nothing here depends on it.
- **Across packages.** `ContractDecl.isPure` existed but the writer always
  set it to `false`. The writer now records `@pure`, and the restored-source
  synthesiser re-emits `@pure` ahead of the function's repr. A package built
  by an older compiler carries no purity, so a consumer's clause calling it
  is rejected until that package is rebuilt.

`ResolvedSignature` gains `isPure`. Record, impl and protected `func`
members take it from their annotations. Protected `entry` members are never
pure.

## Fallout

The repository had about twenty calls to non-`@pure` functions across 709
clauses. Each callee was checked and found side-effect-free, then annotated:

- `Std.Json`: `hasProperty` and `isJson*`;
- `Std.HttpEngine`: `isResponseSafeString` and `allHeadersResponseSafe`;
- `Std.Encoding.encodeUtf8`;
- lyric-search `isKnownFilterOperator`;
- lyric-auth `maxClockSkewSeconds`;
- the rbac example's `dominates` and `hasPermission`;
- three self-test helpers.

`method_contracts_self_test.l`'s `counted` is deliberately impure: it
counts clause evaluations. It is marked `@pure` with a comment saying so.

## Tests

`typechecker_self_test.l` has T0132 cases (non-Bool `requires`, `ensures`
with `result`, loop invariant; unknown names and mismatches
reported; `old` and quantifiers accepted) and T0133 cases (non-pure call,
`@pure` call, body calls unrestricted, invariant, built-in members).

## Docs

- Language reference §6.3 enforcement paragraph.
- Book chapter 8 §8.5. Its quantifier paragraph also said a runtime-checked
  `forall` iterates its domain; it now matches D-progress-982.
- Book appendix B.
