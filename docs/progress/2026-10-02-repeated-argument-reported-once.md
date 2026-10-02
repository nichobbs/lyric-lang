# A repeated argument is reported once (#7846 follow-up)

A follow-up to the review of the #7846 fix (PR #8011). A call that gave a
parameter more than once reported the mistake several times:

- `reportRepeatedCallArgs` added one T0042 per extra repetition, so
  `f(a = 1, a = 2, a = 3)` gave two.
- `checkCallArgsAgainstSig` then ran its arity check
  (`args.count > sig.params.count`) and per-argument pairing on the same
  argument list. Against a two-parameter `f`, the three arguments added a
  third T0042, "expected 2 argument(s), got 3".

Both are fixed:

- `reportRepeatedCallArgs` reports each repeated name once.
- `checkCallArgsAgainstSig` stops after a repeated argument. That covers
  functions, methods, `impl` and interface members and `extern func`s.

The constructor and union-case paths (T0104) share the per-name
deduplication. `typechecker_self_test.l` asserts exactly one T0042 for
`f(a = 1, a = 2, a = 3)` and for `x.m(a = 1, a = 2, a = 3)`.
