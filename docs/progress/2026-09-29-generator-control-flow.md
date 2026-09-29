# `match`, `try`/`catch`/`finally` and `defer` inside an async generator body (#7729)

On `--target dotnet`, three generator-body shapes failed:

```lyric
async func g(o: in Option[Int]): Int {
  match o { case Some(v) -> yield v; case None -> yield 0 }  // build panic
}
async func h(): Int {
  try { risky() } catch Bug as e { log(e) }                   // build panic
  yield 1
}
async func k(): Int {
  try { yield 1 } finally { cleanup() }                       // invalid IL
}
```

## Field-count prediction for `match` and `try`

A generator hoists every `MoveNext` local to a field of its class. Pass 1
(`countGeneratorFieldsMsil`) has to predict how many before any body is
lowered, because every later type's FieldDef tokens depend on it. It did not
count a `match` scrutinee temporary, the slots a pattern allocates (case
casts, extracted fields, tuple elements, bound names), a catch clause's
exception binding, a `try`/`defer` value temporary, the temporaries a binary
operator allocates (`String` `+` stashes both operands), or a `yield`'s
operand. The build then panicked in `synthesizeGeneratorMsil`'s cross-check.

This follows the contract #7718 set up for `for` loops: each count is
declared once, next to the lowering that allocates the slots.

- `patternTestSlotsUpperBoundMsil` / `patternBindSlotsUpperBoundMsil` give
  the most slots `lowerPatternTestMsil` / `lowerPatternBindMsil` allocate for
  each pattern shape: constructor, tuple, record, type test, or-pattern, and
  nested ones. Every `match` arm and every destructuring `val` checks its real
  allocation against them (`checkPatternSlotsMsil`). This runs on every
  function the compiler lowers, so drift fails the compiler's own build.
  `for` patterns use the same bind bound. `forPatternSlotsUpperBoundMsil` is
  gone.
- `matchScrutineeTempSlotsMsil`, `catchBindingSlotsMsil`,
  `valueRegionResultTempSlotsMsil` and `binopTempSlotsUpperBoundMsil` declare
  the remaining temporaries. Every catch clause checks its exception binding
  against `catchBindingSlotsMsil` (`checkCatchBindingSlotsMsil`). The
  predictor also counts match guards and `yield` operands now.
- The prediction stays an upper bound, and the class is padded up to it.
- If the real count still exceeds the prediction, the panic now names the
  construct. Each statement records the slots it allocated, and
  `describeGenFieldOverflowMsil` reports the innermost statement whose hoisted
  locals exceed its prediction, with line and column (for example: "The `match`
  expression at 85:5 hoists 25 locals but countGenLocalsStmt predicts at most
  17").

## `yield` inside a protected region

The generator resumes through a `switch` on `_state` at the top of
`MoveNext`. For a `yield` inside a `try`, the switch branched straight into
the protected region, which the CLR rejects ("Common Language Runtime detected
an invalid program"). The same happened to a `for` over a `Set[T]` or any
extern `IEnumerable`, whose protocol wraps the loop in `try`/`finally`.
`synthesizeGeneratorMsil` now uses the lowering C# uses for iterators
(D142):

- The top-level switch sends each state to the first instruction of the
  outermost region around its `yield`. There, `genRegionDispatchMsil`
  inserts a second switch that re-dispatches to the resume label, or to the
  next nested region. This applies to user `try` (statement and value form),
  `defer`, and the `IEnumerable` loop protocol.
- A resumed generator sets `_state` back to -1, so a region's dispatch falls
  through when the region is entered normally. A finished generator (-2)
  stays finished.
- A `finally` whose region contains a `yield` is skipped while the generator
  suspends through it (`genFinallyGuardBeginMsil`), so it runs exactly once.
- `DisposeAsync` used to be a no-op. It now resumes a generator suspended at
  a `yield` once, in dispose mode (a new `_disposeMode` field). The resume
  path leaves to the completion epilogue, running the pending `finally` and
  `defer` blocks, and any exception they throw is rethrown to the consumer.
  A `for` over a generator already calls `DisposeAsync` on `break`.

A `yield` inside a `catch`, `finally` or `defer` block is now the type error
**T0142** on every target. Those blocks run while an exception or an exit is
in flight and cannot be suspended and re-entered. A `yield` in the `try` body
is allowed whatever handlers the `try` has, so Lyric does not copy C#'s ban on
`yield` inside a `try` that has a `catch`. The rule is in docs/01 §7.2, the
book's §10.5 and its T-code table.

## Tests

- `lyric-compiler/lyric/generator_control_flow_self_test.l`, dual-target,
  11 cases:
  - `match` over an `Option` and over a user union, with payload binds,
    nested constructor patterns and guards
  - tuple and record patterns
  - `match` as a value
  - `yield` inside `try`/`finally`, nested `try`/`finally`, a `try` in a
    loop, after a `defer`, and a `match` inside a `try`, each with its
    `finally` observed exactly once
  - a record declared after every generator
- `lyric-compiler/lyric/generator_control_flow_dotnet_self_test.l`,
  dotnet-only, 9 cases. Each case is there because of a named JVM gap:
  - `try`/`catch` in the body, with `as e` and `as _`, and a `yield` in a
    `try` with `catch` and `finally` (JVM: #7720)
  - a consumer `break` that runs pending nested `finally` and `defer` blocks
    once (the JVM producer thread is abandoned, #3565)
  - `for` over a `Set[Int]`, including a `break` inside it (JVM: #7312)
- `typechecker_self_test.l` gains four T0142 cases.

Before the fix, both new files failed to build on dotnet: the `match` and
`catch` generators panicked in Pass 1, and the `try`/`finally` generators
failed at run time with `InvalidProgramException`. Both files pass after it.
The dual-target file passes on `--target jvm`. It is wired into
`compiler-self-tests-batch.sh` and `jvm-generics-self-tests-batch.sh`, and
the dotnet-only file into `compiler-self-tests-batch.sh`.
