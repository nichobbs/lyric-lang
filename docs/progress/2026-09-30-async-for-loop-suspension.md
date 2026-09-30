# MSIL: `for` loops across a real `await` in an `async func` (#7766, #7767)

## #7766 — loop state lost across a suspension

On `--target dotnet` an `async func` is an `IAsyncStateMachine` whose
`MoveNext` is re-entered after every real suspension, and every IL local
reverts to its default on re-entry.  A `for` loop's hidden temporaries and
its pattern's bindings were IL locals, so an `await` in the loop body that
actually suspended lost them.  An `await` that completed synchronously never
exposed this.  Before the fix, the new self-test failed 13 of its 17 cases:

- `for x in genUpTo(4) { await delay(5); ... }`, and the same over a `Set`
  (the `IEnumerable` protocol): `NullReferenceException`, because the
  enumerator was null after resume.
- `var t = 0; for x in [1, 2, 3] { await delay(5); t = t + x }; t` returned
  0 instead of 6.  Ranges, `List[String]` parameters, slices, nested loops,
  `break`/`continue` and `return` from the loop were all silent miscompiles
  of the same kind.  A tuple pattern lost its second binding (`a1` instead
  of `a1b2`).

A `for` loop inside a Phase-B state machine that can suspend now keeps the
state it reads after the body in state-machine fields.  "Can suspend" means
its body contains an `await`, or for a range, its upper bound does, because
the counter already holds `lo` when the bound suspends.  The kept state is:

| Protocol | Fields kept |
|---|---|
| Range | counter, bound |
| Indexed list | list, index, count |
| Slice with the typed-array fast path | the same, plus the array |
| `IEnumerable` | enumerator |
| Generator (`IAsyncEnumerable`) | enumerator |

The pattern's bindings are kept too.  Each value is registered through the
existing promoted-local machinery (`phaseBRegisterAndSyncLocal`).  It is
stored to its field after every write and reloaded at every resume label.
The key is the IL slot, not the name, so two loops binding `x` at different
types get distinct fields.

The element slot, the `MoveNextAsync`/`DisposeAsync` value tasks, the
`IDisposable` probe and the unwinding flag stay IL locals.  None of them is
read across an `await`.

**Field prediction.**  Pass 1 (`countSmFieldsMsil`) reserves these fields
before any body is lowered.  #7447 proposes replacing that prediction with
a side-effect-free dry run of Pass 1.  This fix does not need it: it uses
the same declared-count pattern as #7718's generator temporaries.

- `forProtocolAwaitFieldsMsil` declares the count per protocol.  Every
  lowering checks the declared count against its real registrations
  (`checkForAwaitFieldsMsil`), so the prediction cannot drift silently.
- A collection loop reserves the largest protocol's count, because the
  protocol follows the iterable's lowered type, which Pass 1 does not have.
- The prediction and the lowering use the same "can suspend" predicate.
- The state machine is padded up to the prediction (#6515).

`await` after a `defer` was untested.  The self-test covers it: one `defer`,
two `defer`s interleaved with awaits, and a `defer` inside a loop body
followed by an `await`.  All already pass through #7754's region dispatch.

**JVM.**  `--target jvm` lowers an `async func` synchronously: an `await`
blocks the calling virtual thread.  Loop state therefore lives in ordinary
locals, and the same 19 cases pass there unchanged.

## #7767 — `DisposeAsync`'s `ValueTask` discarded

The disposal `finally` added by #7754 popped the `ValueTask` that
`DisposeAsync()` returns without waiting on it.  It is now waited on with
`AsTask().GetAwaiter().GetResult()`, through a new protocol temporary for
the `TaskAwaiter`.  `forProtocolTempSlotsMsil` for the async-enumerator
protocol goes from 7 to 8.  After the change:

- An enumerator whose disposal completes asynchronously finishes before
  control leaves the loop.
- A faulted disposal rethrows.
- D143's precedence is unchanged, because the wait sits inside the existing
  suppressing `try`/`catch` when an exception is already leaving the loop.
- `AsTask()` on the already-completed `ValueTask` a Lyric generator returns
  yields the cached completed task, so there is no allocation.

The loop already consumes `MoveNextAsync` by blocking (`get_Result`).
Disposal now matches that in every context, `async func` included.  Awaiting
both through the state machine needs `ValueTask` awaiters in Phase B and a
catch-and-rethrow restructuring of the disposal `finally`, because a
`finally` cannot contain a resume point.  That is left as a follow-up.

**Test coverage for #7767.**  No `for` loop can reach an enumerator whose
disposal is genuinely asynchronous today:

- The async-enumerator protocol applies only to `MIAsyncEnumerable`, which
  only Lyric generators produce.  Auto-FFI never maps a BCL
  `IAsyncEnumerable<T>`, such as `ChannelReader<T>.ReadAllAsync`, to it.
- The protocol goes through `IAsyncEnumerable<object>`, which a value-typed
  `IAsyncEnumerable<int>` is not.
- A Lyric generator's `DisposeAsync` completes synchronously and throws
  directly rather than returning a faulted `ValueTask`.

The wait is therefore exercised by the existing disposal tests
(`generator_dispose_self_test.l`, including a panicking `finally` during
disposal) and verified by ilverify phase 4.

## Tests

`lyric-compiler/lyric/async_for_loop_suspend_self_test.l` has 19 cases.
Every one suspends for real through `Std.Task.delay`.  Two of them panic in
the loop body after a resume, over a generator and over a list, and catch
the panic in the calling function: the generator's `finally` runs exactly
once, through the disposal fault handler that marks the loop as unwinding.  The last case checks
that a record declared after every `async func` reads back correctly, which
holds only if each state machine's field prediction held.  The test runs in
the compiler and JVM-generics batches and in `scripts/ilverify-selfhosted.sh`
phase 4.

**Follow-up.**  A `match` arm's pattern bindings were not promoted either:
`match o { case Some(v) -> { await delay(5); v * 2 } }` returned 0 on
`--target dotnet`.  #7816 fixes it with the same slot-keyed mechanism
(`docs/progress/2026-09-30-async-match-suspension.md`).
