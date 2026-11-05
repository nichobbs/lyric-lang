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
  `SortInfo` when its type is known; an array binding a call initialises has
  none, so a numeric element write into it fails closed until annotated (a
  buffer's elements are never range subtypes, T0173). Nested
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

W0002 for `Std.Buffer`'s element clauses is reported when the stdlib is
built, not in each consumer build that compiles the stdlib from source (the
JVM): `quietWarnings` now covers it (`pipeline.l`).

`examples/buffer_proof.l` proves against the real stdlib in CI's
proof-examples step. A refuted access through a `Std.Buffer` result can come
back `unknown` from z3, since the element clauses are quantified; the goal
fails either way.

Tests: `verifier_self_test.l`: `Std.Buffer` results (lengths, elements,
preconditions, annotation rule, a shadowed `buffer`), `for` over each
sequence kind (bounds, element ranges, invariants established and preserved,
the snapshot, the checked index step, ranges and `break` failing closed),
nested writes (read back, frame, bounds at both levels, inner range).

## G2 exit criteria (#7941)

Write isolation: `buffer_self_test.l` (26 tests) and `buffer_spawn_self_test.l`
(7, `spawn` captures) run in CI on dotnet (`compiler-self-tests-batch.sh`),
the JVM (`jvm-generics-self-tests-batch.sh`) and native
(`native-backend-self-tests.sh`), and pass on all three locally.

Per-write cost: `benchmarks/bench_buffer.l` gains `benchArrayInPlaceWrites`,
the same loop of 1,000,000 read-add-writes over an `array[10000, Int]`, whose
writes have no shared-storage check. `lyric bench`, min of 100 runs, one
machine:

| target | buffer | array | extra per write | buffer alloc per run |
|---|---|---|---|---|
| dotnet | 2.75 ms | 2.18 ms | ~0.6 ns | 263 KB |
| JVM | 6.44 ms | 0.31 ms | ~6 ns | 16 MB |
| native | 0.65 ms | 0.08 ms | ~0.6 ns | 302 KB (the `filled` buffer) |

dotnet and native meet the criterion. The JVM does not: a managed buffer's
storage is a `List[T]` (D226), an `ArrayList<Object>` on the JVM, so each
write boxes its `Int`. That is the representation, not the shared-mark check;
it is #8821, and #7941 stays open on it.
