# Verifier: method calls are their own values, loops are proved in an arbitrary iteration (#8101, #8102)

`lyric prove` no longer proves facts about method calls or loops that do not
hold at runtime.

## Method calls (#8101)

Every call whose callee was not a resolved path translated to one shared
`?call` variable, so `a.f() == b.g()` was provable. Now:

- `recv.m(args)` on a value of one of the file's records reaches a dot-named
  `func R.m(self: R, ...)` the file declares (unless `R` declares its own
  method `m`) and is applied by that function's contract — preconditions as
  side goals, postconditions as facts — with a result of its own at each call
  site unless the method is `@pure`. `R.m(args)` on a type name is a call of
  `func R.m` by path.
- Any other method call is an uninterpreted function of the receiver and the
  arguments, one per method name, argument shape and sorts: equal calls are
  equal (congruence), different methods, receivers or arguments are not.
- A call through a computed callee, and every other value the verifier
  introduces (an unmodelled expression, operator or match arm, a havocked
  variable, an uninitialized `var`), is a fresh symbol. Synthesized names use
  `!`, which no Lyric identifier contains; `smtSanitize` now keeps it.

## Loops (#8102)

`wpWhile` checked preservation in the pre-loop state against an invariant
translated before the body ran, so any invariant true on entry was
"preserved", and it dropped the loop condition's own obligations. Now:

- Every variable the condition or body may change — assigned anywhere in it,
  including nested `if`/`match` arms and lambdas, or passed to an
  `out`/`inout` parameter of a declared function or method receiver — is
  havocked to a fresh symbol (with its width and range) before the invariant
  and the condition are assumed.
- Preservation evaluates the invariant over the values the body leaves: the
  invariant is translated with a placeholder per changed variable, and every
  path's end substitutes the variable's value there (`finishPost`).
- The condition's side conditions are goals on entry (under the invariant)
  and after any iteration; the body's side goals hold under
  `invariant and cond`; the body's facts stay inside the preservation goal.
- The body is walked to its end as statements, so a trailing `if` or call
  changes state. A `return` or `?` in a body fails closed (`V0026`), as
  `break` and `continue` already did.

## Related soundness fixes found on the way

- A trailing `if` in any block is walked branch by branch, so assignments in
  its branches are seen; an assignment nested in an expression the verifier
  translates as a value fails closed (`V0026`), as does an expression
  statement that assigns or jumps, instead of being skipped.
- A branch's facts (an `assert` in it, a loop in it that never exits) hold
  only under that branch's condition.
- An `out`/`inout` argument holds a new, unknown value after the call; in the
  callee's `ensures:` the parameter is its post-call value and `old(p)` the
  argument (the old instantiation made `x == old(x) + 1` the contradiction
  `a == a + 1` at the caller). A function's own `ensures:` over an
  `out`/`inout` parameter, and a protected entry's invariant and `ensures:`
  over its `var` fields, are checked against the values they hold when it
  returns — an entry that broke its type's invariant used to be proved unless
  the body asserted it.
- A write to a record field or element fails closed (`V0026`) rather than
  being skipped with a warning: records are references, and the verifier has
  no heap.

Specification: `docs/15-phase-4-proof-plan.md` §5.2–§5.4; book §18.1, §18.4,
§19.7.

Verified by `lyric-compiler/lyric/verifier_self_test.l` (12 new tests, 104
in all, passing: different and equal unmodelled methods, declared methods by
contract and by `@pure` unfolding, broken and kept invariants, exit facts, body
and condition obligations, fail-closed returns and field writes, branch-local
facts, `out`/`inout` arguments, protected-entry invariants, and the trivial
discharger on `if c then p else p`), `verifier_records_self_test.l`, and the
CI `lyric prove` examples (pagination, prove_demo, token_bucket_proof,
unsigned_proof all discharge).
