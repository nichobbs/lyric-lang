# Verifier: Std.Buffer results, `for` over sequences, nested element writes (#8394, #8753)

D378. `lyric prove` now proves code that builds buffers with `Std.Buffer`,
iterates arrays, slices and buffers with `for`, and writes `a[i][j]`.

- **Imported callees** (`driver.l` `importedCallee`, `vcgen_register.l`):
  generic functions over primitives, their type parameters and sequences of
  them are applied by their `requires:`/`ensures:`; a body that reaches other
  names is dropped rather than disqualifying the function. Quantifier
  variables in a clause are checked scope by scope (`namesOnlyIn`). A function
  over `buffer[T]` is skipped where the proved file's `buffer` is another
  type.
- **`Std.Buffer`** (`lyric-stdlib/std/buffer.l`): `filled`, `grow` and
  `truncate` state their elements with `forall` `ensures:` clauses (W0002 at
  runtime, lengths still checked). T0174 accepts `result` as a buffer
  receiver (`bufferReceiverIsStable`).
- **Element types** (`theory.l` `SortInfo.elem`): a sequence's element
  `SortInfo` when its type is known; a binding a call initialises has none, so
  a numeric element write into it fails closed until annotated. Nested
  element reads and writes use the inner levels.
- **`for`** (`vcgen_loops.l` `wpFor`): the `while` rule over a hidden index
  into a hidden snapshot, with the implicit invariant `0 <= k <= s.length`.
- **Side goals** (`wpBindInit`, `wpAfterExpr`, `assert`, `wpAssign`,
  `wpAssignElement`): the facts a statement establishes guard the side goals
  after it (`guardSideGoals`), as they did the postcondition, so a bound or a
  divisor can follow from an `assert` or a callee's `ensures:`.
- **Nested writes** (`wpAssignElement`): `a[i][j] = v` stores back level by
  level; `r.a[i] = v` stays `V0026` (D157 identity).

docs/01 §13 ("Arrays, slices and buffers in proofs"), docs/15 §5.2 and §5.3,
book chapter 19 and docs/12 item 5 describe the model.

Tests: `verifier_self_test.l`: `Std.Buffer` results (lengths, elements,
preconditions, annotation rule, a shadowed `buffer`), `for` over each
sequence kind (bounds, element ranges, invariants established and preserved,
the snapshot, the checked index step, ranges and `break` failing closed),
nested writes (read back, frame, bounds at both levels, inner range).
