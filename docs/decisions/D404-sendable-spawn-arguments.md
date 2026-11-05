# D404 - What may cross a `spawn`: the `Send` marker, T0225 and T0226 (#8492)

**Status:** accepted; builds on D217 and D403, and changes D217 item 1 (the default thread count).

## Context

A spawned task runs at the same time as its spawner on every target: on a JVM virtual thread, on a
.NET thread-pool task, and under the native scheduler with several threads (D217). `List`, `Map`,
`Set`, record `var` fields and host objects are plain memory, so a task and its spawner that both
use one of them race. Nothing checked this, which is why the native multi-threaded scheduler was
opt-in (`LYRIC_ASYNC_THREADS`). docs/04 already rules out global mutable state ("Module-level `var`
is a parser error"), but a module-level `val` can still hold a mutable collection.

The issue proposed admitting a non-sendable argument that is `in` and provably not mutated by the
callee. That is not sound: the spawner can still write the value while the task reads it, and an
`in` parameter of a reference type does not stop either side mutating the object. Lyric has no
ownership transfer (an `out` argument is written by the callee, not given to it), so there is no
"moved" form to admit either. The rule below has no such exemption.

## Decision

1. **`Send` is a structural marker the compiler computes**, like `Plain` (D155): valid in `where`
   clauses (`func run[T](x: in T): Unit where T: Send`), never in `derives` or `@derive` (T0108-style
   rejection, as for `Plain`), and never implemented by hand. A type is `Send` when sharing one value
   of it between tasks cannot race:
   - the primitives (`String` included, it is immutable), `Unit`, enums;
   - a distinct type or range subtype over a `Send` type;
   - a tuple, nullable, `array[N, T]`, `slice[T]` or `buffer[T]` of `Send` elements (arrays and
     buffers are values, D157 and D186; a slice cannot be written in place, §2.7);
   - a record, exposed record or opaque type with no `var` field whose fields are all `Send`, and a
     union whose case fields are all `Send` (`Option[T]` and `Result[T, E]` are `Send` when their
     arguments are);
   - every `protected type` (its monitor serialises access, §7.5);
   - a task handle `Task[T]` when `T` is `Send` (several tasks may await one handle);
   - a type parameter whose binder declares `where T: Send`.

   Everything else is not `Send`: the stdlib collections (`List`, `Map`, `Set` and other extern host
   types), records with a `var` field (they have identity, D157/D222), interfaces (the
   implementation is unknown), function values (their captures are unknown), `NativePtr`, and a type
   parameter without a `Send` bound.
2. **`@sendable` for types that synchronise themselves.** Some host types are built to be shared
   between threads (`System.Threading.CancellationToken`, `ConcurrentQueue`, `SemaphoreSlim`,
   `java.util.concurrent.LinkedBlockingQueue`, `AtomicBoolean`), and some kernel records guard their
   state with the runtime's locks (the native `HttpListener`, `CancellationTokenSource`). Their
   structure says nothing of that, so the kernel that binds them asserts it: `@sendable` on an
   `extern type`, record or opaque type makes it `Send`. The assertion is outside what the compiler
   checks, so it needs an `@axiom("...")` saying why on the same declaration or its package, which
   docs/17 audits; `@sendable` elsewhere, or without an axiom, is **T0227**. This is the escape the
   issue allowed "only if a real use case appears": the stdlib's own concurrent HTTP server and
   cancellation tokens are that case. There is no escape for a Lyric value whose sharing would race.
3. **T0225 - a spawned call's arguments.** In `spawn f(a, b)` and `spawn r.m(a)`, every argument and
   the receiver must have a `Send` type, and none may be passed `out` or `inout` (the task would
   write the spawner's variable while the spawner runs). A `spawn` whose callee is a function value
   (a local closure, a lambda) is T0225 too, because its captures cannot be checked; spawn a named
   function. The message names the argument, its type, which part of the type is not `Send` and why,
   and the ways out: share it through a `protected type`, pass an immutable copy (a `slice`), or
   build the value inside the task.
4. **T0226 - module state reached from a spawned call.** The checker follows the spawned callee and
   every function of the same package it calls, directly or transitively, and reports each
   module-level `val` they read whose type is not `Send`, naming the `val`, its type and the call
   chain that reaches it. A module-level `val` of a `Send` type (a constant, a lookup table of
   records, a `protected` instance) is fine. Reads count as well as writes, because the spawner, or
   another task, may write the value while the task reads it.
5. **Where it runs.** Both checks are in the type checker, which every backend shares, so they hold
   on `--target dotnet`, `--target jvm` and `--target native` alike. The mode checker, where the
   issue first placed them, sees no types.
6. **Existing code.** A sweep of every file that spawns found the shared mutable state the rule is
   for: native self-tests that logged into one `List` from several spawned tasks (rewritten over a
   protected log), a JVM self-test whose spawned lambda polled a `var` the scope body wrote (now a
   protected flag), and a self-test that passed an `inout` place to a spawned task (removed: the task
   wrote the spawner's variable concurrently). The stdlib and the ecosystem libraries spawn nothing
   that the rule rejects.
7. **A spawned task retains its arguments before it is queued.** Running the native self-tests with
   the multi-threaded default found a D217 bug: a coroutine's deferred-start suspend came before it
   retained its reference parameters, so a spawner that built a temporary argument
   (`spawn tagIt("le" + "ft", 20)`) released it while the task was still queued and the task read
   freed memory. The prologue now retains the parameters first, as an awaited call always has.
8. **The native default becomes multi-threaded.** With the check in place, `LYRIC_ASYNC_THREADS`
   defaults to the number of processors the process may run on (`sysconf(_SC_NPROCESSORS_ONLN)`,
   `GetActiveProcessorCount` on Windows), capped at 256; `LYRIC_ASYNC_THREADS=1` keeps the
   cooperative single-threaded scheduler, and wasm32 is always single-threaded. Which thread runs a
   task, and the order in which ready tasks run, is unspecified (D403), as it already is on the
   managed targets.

## Not in this decision

- **Calls into other packages are not followed** by T0226: a dependency's function bodies are not
  available to the checker of a consumer. A package's own spawns are checked when it is compiled; a
  per-function summary of "reaches non-`Send` module state" in package interfaces (docs/70
  `Lyric.Iface`) would let a consumer follow a call across packages, and is tracked in #8807.
- **`Std.Task` and `Std.Parallel` closures** (`scopeSpawn`, `forChunks`, `lyric_thread_spawn_detached`)
  run a closure on another thread outside `spawn`; checking their captures needs the same rule for
  closure captures and is tracked in #8808.
