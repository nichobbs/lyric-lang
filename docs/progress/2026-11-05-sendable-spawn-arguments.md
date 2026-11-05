# What crosses a `spawn`: the `Send` marker, T0225, T0226, T0227, and a multi-threaded native default (#8492)

D404. The type checker, which every backend shares, now checks what a spawned task shares with
its spawner:

- **`Send`** (`typechecker_send.l`) is computed from a type's structure, like `Plain`: primitives,
  enums, distinct and range types, tuples, nullables, arrays, slices and buffers of `Send`
  elements, records, exposed records and opaque types with no `var` field and `Send` fields,
  unions with `Send` case fields, protected types, `Task[T]` of a `Send` `T`, and type parameters
  bounded `where T: Send` (checked at instantiation as T0108). `@derive(Send)` is T0172.
- **T0225**: an argument or receiver of a spawned call whose type is not `Send`, one passed `out` or
  `inout`, or a spawned call through a function value. The message names the argument, the part of
  its type that is not `Send`, and the ways out.
- **T0226**: the spawned callee, or a function of the same package it calls, reads a module-level
  `val` of a non-`Send` type; the message shows the call chain. The checker records each body's
  calls and module-value reads as it checks it, then walks the graph from every spawn. Calls into
  other packages are not followed (#8807); closures run by `Std.Task`/`Std.Parallel` are #8808.
- **`@sendable`** marks a host type or kernel record that synchronises itself (`CancellationToken`,
  `ConcurrentQueue`, `SemaphoreSlim`, `LinkedBlockingQueue`, `AtomicBoolean`, the native
  `HttpListener` and `CancellationTokenSource`); it needs an `@axiom` on the declaration or its
  package (docs/17's baseline lists the new ones) and is otherwise **T0227**.
- **Native default**: `LYRIC_ASYNC_THREADS` unset now means one scheduler thread per processor
  (`lyric_processor_count`, at most 256); `1` keeps the cooperative scheduler.

Native codegen fix found by the new default: a coroutine's deferred-start suspend (D217) came
before it retained its reference parameters, so a temporary argument of a spawned call could be
freed while the task was queued; the prologue now retains first
(`llvm_self_test_async_mt.l` has an AddressSanitizer case with temporary `String` arguments).

A sweep of every file that spawns, on `--target dotnet` and `--target jvm`, found shared mutable
state only in tests, which were rewritten: native self-tests that logged from several spawned
tasks into one `List` (now a protected log), a spawned lambda that polled a `var` the scope body
wrote (now a protected flag), and an `inout` place passed to a spawned task (removed). Tests:
`typechecker_self_test.l` (T0225, T0226, T0227, `Send` bounds, T0172), the compile-fail corpus
(`testdata/reject/spawn_argument_not_send`, `spawn_reads_module_state`, on dotnet and the JVM), and
`llvm_self_test_async_mt.l` now runs fork-join, sleepers, the contended counter and the rendezvous
with the default thread count, and keeps the cooperative case under `LYRIC_ASYNC_THREADS=1`.
