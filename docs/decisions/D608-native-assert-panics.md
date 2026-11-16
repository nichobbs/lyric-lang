# D608 - `Std.Testing.assertPanics` on native runs the body in a forked child (#9141)

**Status:** accepted; shipped for Linux and macOS. Windows and wasm32-wasi have
no twin and fail the assertion with a message saying so (tracked below).

## Context

`assertPanics` and `assertPanicsWith` were written with `try`/`catch`.
`--target native` has no unwinding (D-N-003): a panic ends the process, so the
construct cannot be lowered and any file that reached `Std.Testing` with the
function in it stopped with `N0007`. That kept every test file that calls
`assertPanics` off native, among them the hermetic suites of `cache-redis`,
`session-redis` and `cache-memcached` in lyric-ecosystem.

## Options

- **(a) `setjmp` in `assertPanics`, `longjmp` from `lyric_panic_msg`.** The
  body keeps running in the caller's process, so its effects are visible
  afterwards. Rejected: the jump abandons every frame between the panic and
  the scope without running anything. Reference counts held by those frames
  are never released (every trapped panic leaks, and the AddressSanitizer flow
  the native self-tests use is a leak check); `defer` blocks do not run, which
  the managed targets do; a panic raised inside the runtime (list and map
  kernels, the scheduler's monitor, a protected type's lock) unwinds past held
  mutexes, so the next caller deadlocks; a panic in a coroutine or on another
  thread has no `jmp_buf` to return to. Each of these is a silent corruption
  or hang, not a test failure.
- **(b) Run the body in a forked child and read how it ended.** Chosen.
- **(c) Re-execute the test binary for one test.** The body is a closure, not
  a name; there is nothing to pass to a second process.

## Decision

`Std.PanicTrapHost` is a kernel with a twin per kernel tree, the pattern of
`Std.PanicGuardHost`. `_kernel/` (dotnet, JVM) wraps `try`/`catch Bug` and
returns `PtRan`, `PtPanicked(message)`. `_kernel_native/` calls three lyric-rt
functions. `Std.Testing` calls `trapPanic(fn)` and matches the result, so the
file `testing.l` has no `try` and builds for native.

1. `lyric_panic_trap_enter()` flushes stdio, makes a close-on-exec pipe and
   `fork`s, returning twice like `fork(2)`. In the child it records the
   pipe's write end and returns 0; in the parent it returns a handle (pid and
   read end).
2. The child runs `fn()`. A panic reaches `lyric_panic_msg`, which sees the
   recorded descriptor, writes `P` and the message to it, flushes stdio and
   `_exit`s with status 113, so the panic text does not reach stderr (the
   managed targets print nothing either). Returning normally ends in
   `lyric_panic_trap_child_done` (`_exit(0)` after flushing).
3. `lyric_panic_trap_join(handle)` reads the pipe to its end (the message is
   cut at 1 MiB; the child is never left blocked on a full pipe), reaps the
   child and returns a string whose first byte says how it ended: `R`
   returned, `P` panicked (the rest is the message), `F` ended the process
   some other way (the rest says how: an exit status other than a panic's, or
   the signal that killed it). The kernel turns these into `PtRan`,
   `PtPanicked("panic: " + message)` (the envelope the managed targets add)
   and `PtFailed(reason)`. `PtFailed` is a failed assertion: a body that calls
   `exit` or crashes did not panic, and is not reported as if it had.
4. Nested use works: the outer child is itself a parent. A failing inner
   assertion panics in the outer body and is trapped by the outer one, as on
   the managed targets. The process and the remaining tests continue; a
   trapped panic costs one fork.

Why this is correct where (a) is not: nothing is abandoned in the parent. The
child's frames, reference counts, locks and coroutines die with it. Under
AddressSanitizer the child ends in `_exit`, which skips the leak check, and the
parent allocated nothing for it.

## What it cannot do

- **The body's effects on memory stay in the child.** A
  list it fills, a protected value it changes keep their old value in the
  caller. Effects outside the process (files, sockets, terminal output) are
  real, and output the body writes is flushed. A test that asserts on state
  a panicking body changed must read it from outside the process or make the
  change before the call. This differs from dotnet and the JVM and is pinned
  by a test (`assert_panics_native_tests.l`).
- **A body that needs threads the parent started.** The child has the
  calling thread only. A body that uses `Std.Parallel`'s worker pool, or the
  multi-threaded coroutine scheduler's workers (D217, D404), after the parent
  has already started them, can wait for threads that do not exist in the
  child. Threads a body starts itself work. The usual body, a synchronous call
  that is expected to panic, is not affected.
- **Forking a multi-threaded process.** The child runs ordinary code, not
  only async-signal-safe calls, so it is safe only when no other thread held
  a lock at the instant of the fork. The system allocator and stdio take care
  of their own locks; a lock in the program's own state is not covered. A
  test that expects a panic while another thread is mid-operation on shared
  state is outside the contract.
- **A crash is not a panic.** A segmentation fault or an `abort` outside
  `lyric_panic_msg` in the body fails the assertion (`PtFailed`).
- **No Windows twin yet, and none on wasm32-wasi.** `lyric_rt.c` returns -3
  from `lyric_panic_trap_enter` where there is no `fork`; the kernel reports it
  and `assertPanics` fails with "this target has no fork, so the body cannot be
  run apart from the test process". It never silently passes. A Windows twin
  would start the body in a child process through `CreateProcess` with the test
  binary re-run for one named test, which needs the test runner to name its
  tests; that is a change to `lyric test` and a Windows toolchain this checkout
  does not have.
