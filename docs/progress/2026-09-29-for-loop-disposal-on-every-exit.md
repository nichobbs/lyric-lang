# A `for` loop disposes its generator on every exit (#7754, D143)

After #7729 (D142) a consumer that left a `for` over a generator with `break`
ran the generator's pending `finally`/`defer` blocks. Every other way out of
the loop skipped them:

```lyric
async func g(log: in List[String]): Int {
  try { yield 1; yield 2 } finally { log.add("cleanup") }
}
func first(log: in List[String]): Int {
  for x in g(log) { return x }   // "cleanup" never logged
  0
}
```

## Root cause

Both backends placed the disposal call after the loop, where only exhaustion
and `break` arrive.

- **dotnet**: `emitCollectionForMsil`'s `IAsyncEnumerable` protocol called
  `DisposeAsync` after its exit label, outside any protected region. `return`
  `leave`s to the function epilogue, a labelled jump branches to the outer
  loop, and an exception unwinds — none pass that call. The generator stayed
  suspended and its `finally` never ran.
- **jvm**: the `Iterable` arm of the `for` lowering called
  `AutoCloseable.close()` after `endLB`. `return` and labelled jumps replay
  `ctx.deferStack`, which held only `defer`/`finally` blocks, and no handler
  covered the loop. The producer stayed parked until the GC-driven cleaner
  interrupted it, so the `finally` ran at an arbitrary later time, if ever
  before exit.

## Fix

- **dotnet**: both enumerator protocols (`IAsyncEnumerable` and the
  non-generic `IEnumerable` used for `Set[T]` and extern collections) now
  share one disposal region, `beginForDisposeRegionMsil` /
  `endForDisposeRegionMsil`: a `try`/`fault` (sets an "unwinding" flag) inside
  a `try`/`finally` whose handler disposes. The `finally` is the single
  disposal point; the loop's `break` targets a label inside the region, so it
  leaves through the `finally` like every other exit and never disposes twice.
  In a generator the region takes part in D142's resume dispatch and its
  `finally` is skipped while suspending.
- **dotnet async functions**: an `await` in the loop body now sits in that
  region, so the async state machine (Phase B) gains the same region dispatch
  generators use. `PhaseBCtx.dispatchTargets` redirects each await's state to
  the outermost enclosing region's first instruction, which re-dispatches, and
  a region `finally` is skipped while `__state >= 0`. The shared helpers
  (`genRegionMarkMsil`, `genRegionDispatchMsil`, `genFinallyGuardBeginMsil`)
  select the generator or async state field.
- **jvm**: `FuncCtx.deferStack` now holds `DeferEntryJvm` cleanups: a
  `defer`/`finally` block or a `DeferCloseIterJvm(itorSlot)`. The loop pushes
  its close for the body, so `return` and labelled jumps replay it in order
  with other pending cleanups; its own `break`/`continue` do not. A catch-all
  handler (`emitForCloseHandlerJvm`) closes the iterator on an exception,
  guarded by the existing "already replayed" flag.
- The async-enumerator protocol also narrows its `object`-typed generator and
  enumerator slots with `castclass` before each interface call, so its IL
  verifies.

## Exception precedence

An exception from the disposal propagates when the loop is left normally. When
an exception is already leaving the loop it wins: the JVM attaches the
disposal's exception with `addSuppressed`; .NET has no suppressed-exception
list, so dotnet drops it. This departs from C#'s `foreach`, where the
disposal's exception replaces the one in flight; D143 records why.

## Tests

`lyric-compiler/lyric/generator_dispose_self_test.l` (10 cases, both targets,
wired into `compiler-self-tests-batch.sh` and `jvm-generics-self-tests-batch.sh`):
`return` (ordered before the consumer's own `defer`), a panic caught by the
caller, `?` propagation, `break outer`, `continue outer`, a labelled
`continue` inside another generator, stopping an outer generator suspended in
its loop over an inner one, `return` after an `await` in an `async func`, a
`finally` that panics on `return`, and the consumer's panic winning over a
panicking `finally`. Before the fix all 10 failed on both targets; after, all
10 pass on both.

## Not addressed

An `async func` on dotnet does not keep a `for` loop's own temporaries
(enumerator, list, index) across a real suspension: `for x in xs { await
delay(5) }` computes the wrong result or throws on resume. This predates
#7754 and is unchanged by it; synchronously completing awaits work.
