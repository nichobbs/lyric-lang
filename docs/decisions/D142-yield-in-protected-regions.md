# D142 — Where a generator may `yield` inside `try`/`defer` (docs/01 §7.2) (#7729)

**Status:** accepted, implemented

## Context

docs/01 §7.2 said nothing about `yield` inside `try`, `catch`, `finally` or
`defer`. The JVM generator runs its body to completion on a producer thread,
so any placement worked there. The MSIL generator is a state machine that
suspends by leaving `MoveNext` and resumes through a `switch` on its state;
a `yield` inside any protected region produced invalid IL, because the
resume branch jumped straight into the region.

C# allows `yield return` in a `try` with a `finally`, and forbids it in a
`try` that has a `catch`, in a `catch` and in a `finally`. The `try`-with-
`catch` rule exists for C#'s own lowering reasons; nothing in Lyric's
lowering needs it.

## Decision

1. A `yield` may appear in the protected body of a `try`, whatever handlers
   the `try` has, and among the statements a `defer` guards. Suspending
   there does not run the enclosing `finally`/`defer` blocks. They run
   exactly once, when control leaves the region for good.
2. A `yield` inside a `catch` handler, a `finally` block or a `defer` block
   is a compile error, **T0142**, on every target. Those blocks run while an
   exception or an exit is in flight. The CLR cannot branch back into a
   handler, and a Lyric program that suspends mid-cleanup has no sensible
   resumption semantics on any target.
3. When a consumer stops early, a generator suspended inside a `try` runs its
   pending `finally`/`defer` blocks, innermost first, and an exception one of
   them raises reaches the consumer. On `--target dotnet` this happens in
   `DisposeAsync`, which the `for` loop calls. On `--target jvm` the producer
   thread of an abandoned generator stays parked (#3565), so the blocks do not
   run there yet. That is a known JVM gap, not a different semantics.

## MSIL lowering

This is the lowering C# uses for iterators:

- The top-level dispatch sends each suspended state to the first instruction
  of the outermost protected region enclosing its `yield`. There a second
  `switch` re-dispatches to the resume label, or to the next nested region.
  Branching to a region's first instruction is legal.
- A resumed generator resets its state to -1, so a region's dispatch falls
  through when the region is entered normally.
- A `finally` (or the `for` loop's enumerator-disposal handler) whose region
  contains a `yield` runs only while the state is negative. The suspending
  `leave` passes through it with the state still at the yield's index.
- A `_disposeMode` field lets `DisposeAsync` resume a suspended generator
  once. The resume path then leaves to the completion epilogue, running the
  pending `finally` blocks.
