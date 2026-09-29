# JVM async generators: `this`-slot fix and a pull-driven rendezvous (#7720)

`async_generator_self_test.l` passed 16/16 on `--target dotnet` but failed
4/16 on `--target jvm`, where CI did not run it.

## Slot 0 clobbered in `run()`

`lowerAsyncGenerator` (`lyric-compiler/jvm/lowering.l`) sized the generator's
`run()` locals by scanning the body for the highest slot it touched, starting
from 0, and put the yield scratch slot one past that. The codegen reserves
slot 0 for `this` and allocates body locals from slot 1, but a generator with
no parameters and no locals (`yield 1; yield 2; yield 3`) touches no slot at
all, so the scratch slot was 0: every `yield` did `astore_0`, overwrote
`this`, and the class failed verification ("Incompatible type for getting or
setting field"). Cases 1, 2 and 6 hit this.

The yield and exception-handler sequences no longer use a scratch local: the
value goes to a `_yield(Object)` helper, and an escaping exception to a
`_fail(Throwable)` helper, on the operand stack. `max_locals` is
`max(1, <slots the body uses>)`, computed by `maxSlotUsedByInsns`, which is
now shared with `inferMaxLocals` (the generator's own scan also missed
`LAstoreAs` and `LIinc`).

## Producer ran ahead of the consumer

The old design handed values across one `SynchronousQueue`. The producer
started in `iterator()`, and after each hand-off it went straight on to the
next `yield`, so the body ran one step ahead of the consumer. Case 15, the
#5102 interleaving probe, read `P0 P1 C0 ...` instead of `P0 C0 P1 ...`. A
body exception was swallowed: the consumer saw a normal end of sequence.

The generator is now a per-element rendezvous that matches the MSIL state
machine:

- The factory returns a `<G>` that holds only the parameters. `iterator()`
  clones it into fresh producer state and returns a `<G>$Iter` over it, so each
  iteration is independent.
- The first `hasNext()` starts the producer virtual thread. The producer's
  first action is to wait on a `_demand` queue, so no body code runs before
  the first pull.
- Each pull puts a demand token and takes the next value. Each `yield` puts
  the value, then waits for the next demand. Exactly one element is produced
  per pull. `hasNext()` is idempotent, and `next()` without `hasNext()` pulls.
- An exception that escapes the body is stored and the done sentinel is
  handed over. The pull that receives it rethrows the original exception on
  the consumer thread.
- Abandonment: `<G>$Iter` is registered with a per-generator-class
  `java.lang.ref.Cleaner`, whose thread is a virtual thread. When the iterator
  becomes unreachable, the cleaner sets `_abandoned` and interrupts the
  producer. The producer's pending `yield` throws `InterruptedException` and
  unwinds the body, and the completion paths never block once abandoned. This
  matters because the JDK tracks every started virtual thread
  (`jdk.trackAllThreads`), so a parked producer is never reclaimed by GC
  alone. This replaces the previous "parked until GC" behaviour, which in
  practice leaked every abandoned producer (reported in #3565, which was
  closed with documentation only). A Lyric program that breaks out of 100,000
  generators after two elements each, where each generator keeps a 200-string
  list live across its `yield`s (over 1 GB if leaked), completes under
  `java -Xmx64m`.
- If the consumer thread is interrupted while waiting, the iteration ends,
  the producer is released, and the interrupt status is restored.

A bare `return` in a generator body now routes through the completion path,
so the consumer receives the done sentinel instead of blocking forever. The
body's own `try`/`catch` handlers are now registered in `run()`'s exception
table. `lowerInsn` treats `LTryCatch` as a no-op, and the generator path never
ran `lowerFunc`'s handler pre-pass, so a handler in a generator body was
silently dropped.

## Tests

- `async_generator_self_test.l` gains four dual-target cases: a zero-param,
  zero-local `Long` generator; straight-line interleaving over four yields
  plus the tail; an early `break` that pins the producer to the last pulled
  `yield`; and a body panic that propagates to the consumer on the third pull.
  It passes 20/20 on both targets, and is now in
  `scripts/ci/jvm-generics-self-tests-batch.sh`.
- The new `lyric-compiler/jvm/generator_body_try_catch_jvm_self_test.l`
  (2 cases, also in the JVM batch) covers `try`/`catch` in a generator body.
  It is JVM-only because the dotnet backend rejects a `try`/`catch` in a
  generator body at build time (`countGeneratorFieldsMsil` field-count
  prediction mismatch), which is a separate MSIL gap.
- `generator_for_loop_self_test.l` and
  `generator_closure_var_capture_self_test.l` still pass on both targets.
