# Verifier: obligations inside blocks, unmodelled operands and division by zero (#8107)

`lyric prove` discharged goals without checking obligations a program
incurs in four places; each is now modelled or fails closed.

- **Blocks used as values** (an `if`-expression's branch, a match arm, a
  `{ ... }` expression): only the last expression was translated, so
  statements before it — a callee's precondition, an `assert`, a binding
  the value needs — were dropped, and a match arm block was an unknown
  (V0028). `translateBlockValue` now walks the statements in order:
  bindings are scoped to the block, `assert`s are obligations and then
  facts, every side condition and fact stands, and `out`/`inout` arguments
  take new values. An assignment, a jump (`return`, `break`, `continue`,
  `throw`, `?`) or a loop inside such a block fails closed (V0033).
- **Statement-level `match`** was already translated with its side
  conditions since #8140; its block arms now go through the same block
  walk.
- **Unmodelled operators and constructs** (V0023, V0024) discarded their
  operands' obligations. The value is still unknown, but the operands and
  evaluated subexpressions (index, tuple and list elements, interpolation
  segments, `await`/`try`/`?` operands, range bounds) keep their
  obligations and facts.
- **Division by zero**: integer `/` and `%`, and `/=`/`%=`, carry the
  obligation `divisor != 0` in every mode; real division has none. Under
  `checked_arithmetic`, a signed `/` also carries its width bound, which
  catches `MinValue / -1`; `MinValue % -1` remains #7882.

Also: a `?` or other jump in a loop condition fails closed explicitly
(V0026, #8143 item 1), and a self-test pins `Lyric.Parser.pairCallArgs` to
the type checker's pairing for a named argument followed by a positional
one (`f(b = 1, 2)`).

Specification: `docs/15-phase-4-proof-plan.md` §5.2, §5.4.

## Review follow-up

The review found more obligations dropped in the same class, each a
program `lyric prove` discharged and `lyric run` violated:

- A match arm's guard was never translated (a fresh unknown stood for it);
  it now is, in the arm's bindings, with its side conditions and facts
  holding where the pattern matches, and the arm taken when it holds.
- An arm whose pattern is unsupported (V0027) was skipped, body and all;
  its guard and body are now checked under an unknown condition, its
  bindings fresh.
- Lambda bodies were never checked. A lambda is now walked as a function
  body for every call: parameters fresh at their declared sorts, mutable
  captures havocked, other captures at their values; nothing it
  establishes is assumed outside it.
- `a ?? b` kept `b`'s side conditions and facts unguarded although `b`
  runs only when `a` is null; they now hold under an unknown condition, so
  `b`'s obligations must hold and its facts give nothing. (`and`, `or`,
  `implies`, `if` and `match` were already guarded; Lyric has no other lazy
  operator.)
- Signed `MinValue / -1` and `MinValue % -1` trap in every build profile
  (D163); every signed `/`, `%`, `/=` and `%=` now carries `not (dividend
  == Min and divisor == -1)` for its width in every mode. This closes
  #7882. `examples/unsigned_proof.l`'s remainder example had that very bug
  and now excludes `d == -1`; book §18 exercise 1 points it out.

## Second review

- A signed division whose width the verifier did not know took the 32-bit
  minimum, so a `Long` `MinValue / -1` (or `% -1`) through a match binding
  proved. An unknown width now excludes both minimums, and a match binding
  of the whole scrutinee carries the scrutinee's width and range. The
  other uses of the 32-bit default (`+`, `-`, `*`, negation overflow) only
  make their obligations stricter.
- `out`/`inout` calls inside one expression were not sequenced: what the
  expression evaluated later (branches, arms, a guard's arm body, a right
  operand, later arguments) was translated in the state before the call.
  Each of those now sees the variables such a call passed in at new
  values.
- A `var` declared in a block used as a value was not marked as a binding
  a call or lambda may change, so a lambda capturing it saw its initial
  value; it now sees an arbitrary one.

## Third review

- A division mixing an operand of unknown width with an `Int` took the
  `Int`'s width, so `b.value / d` with `b` a distinct type over `Long` and
  `d: Int` proved and then threw at run time. An operator, `if` or `match`
  now has an unknown width when any of its operands does (an unsuffixed
  literal excepted), `.value` of a distinct value has the distinct type's
  width and range, and `T.from(x)` has `T`'s width. The overflow
  obligations keep the widest known operand, which is sound for them.
- A guard's `out`/`inout` effects reached only its own arm's body: the
  later arms, which run after the guard failed, were translated in the
  state before it. They now see those variables at new values.
- A call's receiver (`zr(x).take(pos(x))`) or computed callee
  (`pick(zero(x))(pos(x))`) was translated after the arguments, though it
  runs first. The arguments now start from the state it leaves. The other
  constructs (index, interpolation, tuples, lists, field chains) were
  audited and already run left to right.
- Named arguments written out of parameter order run in parameter order on
  the backends but were sequenced as written, so `two(b = pos(x), a =
  zero(x))` proved and failed at run time. The order is not settled in the
  language reference yet, so such a call (or record construction) now fails
  closed with V0033 when an argument changes a variable.

After the fourth review (named-argument order): `verifier_self_test.l`
143 tests, the CI prove examples, `core_proof.l`, the review repros, and
the compiler self-test batch (3361 tests) all pass.

After the third review: `verifier_self_test.l` 142 tests, the CI prove
examples, `core_proof.l`, every earlier repro, and the compiler self-test
batch (3360 tests) all pass.

After the second review: `verifier_self_test.l` 139 tests, the CI prove
examples, `core_proof.l`, every earlier repro, and the compiler self-test
batch (3357 tests) all pass.

After the follow-up: `verifier_self_test.l` 136 tests, the CI prove
examples (unsigned_proof 18/18) and `core_proof.l`, the earlier repros
(only the separately filed ones still prove, plus legitimate programs),
and the compiler self-test batch (3354 tests) all pass.

Verified by `lyric-compiler/lyric/verifier_self_test.l` (131 tests, all
passing; new refute and discharge cases for each item), the CI `lyric
prove` examples (`unsigned_proof` now proves 18 obligations, its divisions
included) and `core_proof.l`, the earlier review repros (no regression),
and the compiler self-test batch (3349 tests).
