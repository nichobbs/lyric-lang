# Tuple pattern arity in `for` bindings and over non-tuples (#7804)

Issue #7804 listed three lenient pattern paths. On current main two were
already fixed: local `val` record and constructor patterns bind typed fields
and check their head (#7810), and a `match` arm tuple pattern of the wrong
arity is T0198. The third, `for` over extern types, is #7809 (PR #8678).

Probing main showed the tuple-arity side still had three holes, all accepted
with no diagnostic and the extra names typed `TyError`:

- `for (a, b, c) in pairs` over `slice[(Int, Int)]`;
- a tuple `for` pattern over a non-tuple element (`for (a, b) in ints`);
- a tuple pattern in a `match` arm over a scrutinee of known non-tuple type
  (`match n { case (a, b) -> ... }` with `n: Int`).

All three are now T0198 (no new code). `checkForTuplePattern` walks a `for`
pattern against the element type at every nesting depth; the `match` arm
check in `bindPatternTyped` also fires when the scrutinee is known and not a
tuple. Unknown, open and `Never` types stay lenient, as for T0146.

Tests: `a tuple pattern needs a tuple to match, in a match arm and in a for
binding (#7804)` in `typechecker_self_test.l`. Docs: docs/01 (`for` and
`match` pattern sections) and the book's T0198 row.
