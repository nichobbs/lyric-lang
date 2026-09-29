# `ensures:` checked when a `Unit` body falls off after any statement (#7747)

A `Unit` function's postcondition was silently never evaluated when its body
ended in anything other than an expression statement, on every target:

```
func bump(x: inout Int): Unit
  ensures: x == 100
{
  x = x + 2          // ensures never evaluated
}
```

The contract elaborator (`Lyric.ContractElaborator`) inserts the `ensures:`
asserts at each `return` and, for the implicit fall-off, around a trailing
`SExpr`. Neither backend has a separate exit-label contract path (the JVM
`lowerFuncWithContract` helper is only reached by its own unit test), so the
elaborator is the only place postconditions are inserted. A body whose last
statement was an assignment (plain, compound, field, index, `out`
parameter), a `while`/`for`/`do` loop, `defer`, `scope`, `try`, a local
binding, or that was empty, fell off without any check. A trailing `if`,
`match` or Unit call parses as an expression statement and was already
checked.

The same path carries protected-type `invariant:` clauses (appended to each
entry's postconditions), record and `impl` methods (including inherited
interface `ensures:`), and the aspect `ensures:` the weaver re-elaborates on
each wrapper, so all of these were skipped the same way. An `entry` ending in
`balance = balance + d` never checked its type's invariant.

Fix: after walking the top-level statements, `elaborateFunctionBody` appends
the postcondition asserts when the function is `Unit`-returning and its body
can fall off without passing a checked exit (`fallsOffWithoutEnsures`): the
body is empty, or its last statement is neither an expression statement nor a
`return` and can complete normally. `stmtAlwaysExits` decides the last part:
`return`, `throw`, a `do` loop no `break` leaves, a `scope` whose body always
exits, and a `try` whose body and every catch always exit (or whose `finally`
does); no assert is added after such a statement, since it would be
unreachable. `blockAlwaysExits`, which the non-`Unit` trailing-value rewrite
uses to skip its result binding, now shares that classification. As at a
`return`, the check runs before pending `defer` blocks.

Non-`Unit` functions have no analogous gap: a body whose last statement is not
an expression, `return`, `throw` or endless loop fails type checking (T0070).

Verified by the new dual-target `contract_fall_off_ensures_self_test.l` (23
cases, wired into `scripts/ci/compiler-self-tests-batch.sh` and
`scripts/ci/jvm-generics-self-tests-batch.sh`): a satisfying and a violating
call for each trailing statement kind listed above, `old()`, a function with
no return type annotation, a record method, an `impl` method's inherited
`ensures:`, a protected entry's type invariant and its own `ensures:`, and an
aspect `ensures:` on a wrapper whose advice ends in an assignment. Before the
fix 19 of the 23 cases failed on both `--target dotnet` and `--target jvm`
(the four that passed are the trailing `if`, `if`/`else`, `match` and Unit
call). `contract_elaborator_self_test.l` gains four shape tests: the assert
after a trailing assignment, an empty body, a `do` loop left by `break`, and
no assert after an endless `do` loop.

No latent violations surfaced: the only `Unit` function with `ensures:` in the
stdlib and ecosystem libraries is `Lyric.Testing.advance`, whose clause holds,
and none of their protected types declares an `invariant:`. Every ecosystem
manifest suite, the JVM ecosystem suites and the dotnet stdlib runtime suites
ran without a new `PostconditionViolated` or `InvariantViolated`.
