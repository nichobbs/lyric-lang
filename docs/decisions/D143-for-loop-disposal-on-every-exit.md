# D143 — A `for` loop disposes its iterator on every exit (docs/01 §7.2) (#7754)

**Status:** accepted, implemented

Extends D142 rule 3, which promised early-stop cleanup only for `break`.

## Context

D142 made a consumer that stops early run a suspended generator's pending
`finally`/`defer` blocks. Both backends did it with a disposal call placed
after the loop: `DisposeAsync` on `--target dotnet`, the iterator's `close()`
on `--target jvm`. Only exhaustion and `break` reach that point. Leaving the
loop by `return`, `?` propagation, a labelled `break`/`continue` to an
enclosing loop, or an exception skipped it, so a `finally` guarding the
generator's suspended `yield` never ran on dotnet, and on the JVM ran only when
the garbage collector reclaimed the iterator.

## Decision

1. A `for` loop over a disposable iterator disposes it exactly once on every
   exit: running to the end, `break`, `return` (including `?` propagation), a
   labelled `break`/`continue` to an enclosing loop, and an exception. The
   disposal runs before control leaves the loop, so before the consumer's own
   enclosing `finally`/`defer` blocks. "Disposable" is a Lyric generator, an
   `IDisposable` enumerator on `--target dotnet`, or an `AutoCloseable`
   iterator on `--target jvm`.
2. An exception the disposal raises propagates from the loop when the loop is
   left normally (end, `break`, `return`, labelled jump).
3. When the loop is being left by an exception, that exception keeps
   propagating and the disposal's exception does not replace it. On
   `--target jvm` the disposal's exception is attached with
   `Throwable.addSuppressed`, as `try`-with-resources does. .NET exceptions
   have no suppressed-exception list, so on `--target dotnet` it is dropped.

Rule 3 departs from C# `foreach`/`await foreach`, whose `finally` lets the
disposal's exception replace the one in flight. The first exception is the
cause of the failure; the cleanup failure is a consequence of unwinding. Java,
Python (exception context) and the JVM target all keep it, and choosing it on
both targets means a Lyric `catch` sees the same exception whichever target
the program runs on — only the diagnostic attachment differs.

## MSIL lowering

The enumerator protocols (`IAsyncEnumerable` for generators, non-generic
`IEnumerable` for sets and extern collections) share one disposal region:

```
unwinding = false
.try { .try { <loop> ; done: leave after } fault { unwinding = true } }
finally { if unwinding { .try { <dispose> } catch Exception { } } else { <dispose> } }
after:
```

The `finally` is the single disposal point, so `break` (which now targets
`done`, inside the region) never disposes twice, and `return` and labelled
jumps `leave` through it. Inside a generator or an async state machine the
region takes part in the D142 resume dispatch and its `finally` is skipped
while the state machine suspends through it.

`async func` state machines now use the same region dispatch for `await`:
each protected region re-dispatches the awaits inside it from its first
instruction, and a `finally` whose region contains an `await` is skipped while
suspending. Without it an `await` in the body of a `for` over a generator
would sit inside the new region and the resume branch would jump into it. A
`try` written in an `async func` still may not contain an `await` (V0012).
A `for` loop's own temporaries (its enumerator, index and bound) are not yet
kept across a real suspension of an `async func`, so an `await` in a loop body
that does not complete synchronously fails on resume on `--target dotnet`, as
it did before this change; that is a separate gap in the async state machine,
not part of this decision.

## JVM lowering

`FuncCtx.deferStack` holds cleanups of two kinds: `defer`/`finally` blocks and
a `for` loop's iterator close. The loop pushes its close for the body, so
`return` and a labelled `break`/`continue` to an enclosing loop replay it, in
order with the other pending cleanups. The loop's own `break` and `continue`
do not (their depth is taken after the push); `break` reaches the close after
the loop. A catch-all handler over the loop closes the iterator, attaches a
close exception to the propagating one with `addSuppressed`, and rethrows; the
existing "already replayed" flag keeps a close that threw during a replay from
running again.
