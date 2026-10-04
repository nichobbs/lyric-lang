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

## Review follow-up

An independent soundness review of the change found eight more holes, each
confirmed by a program `lyric prove` discharged and `lyric run` violated:

- A call's own `ensures:` facts proved its own `requires:` in a loop
  condition, a loop invariant (establish, preserve), a function's
  `ensures:` and an `assert`. Contract expressions now translate to side
  conditions, facts and value; an obligation is `sides and (facts =>
  value)`, and a loop condition's side conditions are guarded by the
  invariant alone.
- `f(a, a)` with two `out`/`inout` parameters now fails closed (V0033).
- A parameter default was translated in the callee's parameter scope; it
  now sees no other parameter, and a default naming an unmodelled value
  (a module `val`) fails closed.
- `P.inc(a)` (package-qualified) and `inc[Int](a, 0)` lost the `out`/`inout`
  havoc; both now resolve like `inc(a)`. A call the verifier cannot resolve
  havocs every `var`/`out`/`inout` binding it is passed.
- A bare call to a protected type's own member from an entry now fails
  closed (V0033) instead of resolving to nothing.
- Expression statements of any form (`(pos(0))`, `pos(0) == 1`) keep their
  obligations.
- `old(e)` for a non-path `e` meant the current value; it is now `e` at the
  entry snapshots.
- A value reported untranslatable (V0033) and then discarded by a
  statement now still keeps a goal failed.

Each fix has a refute case and a discharge case in `verifier_self_test.l`
(112 tests, all passing); the review's repro programs no longer prove, the
CI `lyric prove` examples and `core_proof.l` still discharge, and the
compiler self-test batch passes (3309 tests).

## Second review

Three more holes, each confirmed by a program proved and then violated:

- A callee assumed its `requires:`'s nested-call side conditions, while a
  caller translated that `requires:` without the callee table and never
  proved them; and the side conditions were assumed even where
  short-circuiting skipped the call. Callee contracts are now translated at
  a call against the file's functions (a function reached again inside its
  own contract is not unfolded twice), and every side condition and fact
  is guarded by the condition under which its subterm is evaluated (`and`,
  `or`, `implies`, `if`, match arms), when proving and when assuming.
- `self.m()` inside a protected entry was an unknown method; it now fails
  closed like `m()`, and so does a method call on an unmodelled receiver.
- A local binding shadowing a file function (`val f = { ... }; f(1)`) was
  ignored; such a call now goes through the binding.
- A computed call with an untranslatable argument now keeps its goal
  failed.

`verifier_self_test.l` has 118 tests, all passing; every review repro the
fixes cover no longer proves, the CI `lyric prove` examples and
`core_proof.l` still discharge, and the compiler self-test batch passes
(3318 tests).

## Third review

Unfolding callee contracts at calls opened two holes through recursion,
both confirmed:

- A contract cycle (`ensures: result == f(x) + 1`, or `f`'s ensures
  calling `g` and `g`'s calling `f`) unfolded into contradictory facts
  every caller assumed. The contract-call graph is now checked for cycles
  before goal generation; a function on a cycle has its `requires:` proved
  at calls but its `ensures:` and `@pure` body never assumed.
- A recursive call in a `requires:` was assumed by the callee and never
  proved by callers. A function's own contracts are now translated with it
  on the contract stack, as at its calls, and a call cut there whose
  callee has a `requires:` fails closed (V0033).
- Found while testing: a callee's `ensures:` was instantiated by
  substituting its parameters into a term that already held the call, so a
  caller variable sharing a parameter's name was rewritten inside the
  call's own arguments (`fact(n - 1)` became `fact(n - 1 - 1)`), a fact
  about the wrong term. `result` is now a placeholder substituted with the
  parameters at once.

## Fourth review

No new soundness hole; one crash. A parameter default reaching its own
function (`b: Int = f(0) + 1`) recursed without end in `lyric prove` (a
stack overflow). Defaults are now translated with the callee on the
contract stack and are edges of the contract-call graph; a record field
default that constructs its own record fails closed; and contracts and
defaults unfold at most 32 deep before a call fails closed (V0033).
`verifier_self_test.l` has 123 tests, all passing; the repros no longer
crash (`lyric prove` reports the goals unproved), the CI `lyric prove`
examples and `core_proof.l` still discharge, and the compiler self-test
batch passes (3323 tests).

`verifier_self_test.l` has 122 tests, all passing; the third review's repros
no longer prove, the CI `lyric prove` examples and `core_proof.l` still
discharge, and the compiler self-test batch passes (3322 tests).

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
