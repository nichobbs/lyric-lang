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

Verified by `lyric-compiler/lyric/verifier_self_test.l` (131 tests, all
passing; new refute and discharge cases for each item), the CI `lyric
prove` examples (`unsigned_proof` now proves 18 obligations, its divisions
included) and `core_proof.l`, the earlier review repros (no regression),
and the compiler self-test batch (3349 tests).
