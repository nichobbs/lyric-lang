# D405 - An I/O reactor in the native async scheduler (#8494)

**Status:** accepted, implemented (docs/67 phase G8); builds on D217 and D403.

## Context

Under the native coroutine scheduler a synchronous kernel call inside an `async func` (a socket
`accept`, `read` or `write`, a file read, a `when:` barrier wait) occupies its thread until it
returns. With `N` scheduler threads, `N` tasks waiting on idle connections stall every other
task: an `async` server could serve only as many idle connections as it had threads. Sleep
(`Std.Time.sleepMillis`) and `Std.Process.runCapture` already had async leaves (D-N-022,
D-N-023); the process leaf pumped its pipes on a 1 ms sleep.

## Decision

1. **A readiness reactor in `lyric_async.c`.** `lyric_async_wait_fd(task, fd, events,
   timeout_ms)` parks the running task until `fd` is ready for `LYRIC_IO_READ` and/or
   `LYRIC_IO_WRITE`, or the timeout passes; `lyric_async_wait_fd2` also watches a second
   descriptor (an accept that a stop request on the listener's wake pipe must interrupt).
   Registration is two-phase, like a sleep (D217 rule 3): the call records the intent and the
   thread publishes it once the coroutine has suspended. The task reads the outcome with
   `lyric_async_wait_fd_result`: the ready bits (`LYRIC_IO_ERROR` for an error or hang-up, which
   the next read or write reports), or 0 on timeout. `lyric_fd_wait` / `lyric_fd_wait2` are the
   blocking forms for synchronous callers.
2. **Who polls.** Cooperative scheduler: when no task is ready, the thread polls the parked
   descriptors with the earliest sleeper's deadline as the timeout, instead of sleeping.
   Multi-threaded: one idle thread at a time becomes the poller, blocking in the poll with the
   earliest deadline (sleeper or reactor timeout) while the other idle threads wait on the
   condition variable; a wake pipe in the poll set (a loopback socket pair on Windows) lets a
   thread that makes a task ready, registers a descriptor or adds an earlier sleeper interrupt it
   when no other thread is parked to take the work. Ready and timed-out waiters go to the
   poller's deque (D403). So that busy threads never starve the reactor, a thread polls without
   waiting after every 61st task it runs while descriptors are parked. A `lyric_task_block_on`
   caller reports the existing deadlock only when nothing is ready, running, sleeping or parked on
   the reactor.
3. **`poll`, not `epoll`/`kqueue`.** The reactor uses `poll(2)` on Linux and macOS and `WSAPoll`
   on Windows, rebuilding the descriptor array on each poll. One code path covers every target the
   native backend has; the cost is linear in the parked descriptors per wake, which a thousand
   idle connections do not notice. A per-platform readiness API (epoll, kqueue, IOCP) becomes
   worth its three code paths only when profiles show the rebuild; it is a performance change with
   no semantic one.
4. **The reactor leaf.** `Std.IoWait.waitFd` / `waitFd2` (`_kernel_native/io_wait.l`, a kernel
   package) block in `poll` when called synchronously; inside an `async func` the code generator
   lowers them to `lyric_async_wait_fd` and a suspend point, as it lowers `sleepMillis`.
5. **Socket twins.** `Std.TcpHost` gains `hostAcceptAsync`, `hostReadAsync` and
   `hostWriteAsync`, written in Lyric over new non-blocking runtime calls
   (`lyric_sock_try_accept`, `lyric_sock_try_read_bytes`, `lyric_sock_try_write_bytes`,
   `lyric_sock_io_timeout_ms`): each tries the operation without blocking and waits on the reactor
   while the socket is not ready. Inside a coroutine an awaited call of `hostAccept`, `hostRead` or
   `hostWrite` is lowered as a call of its twin (`Lyric.LlvmCodegen.nativeAsyncTwin`; the bridge's
   reachability walk keeps a twin alive whenever its synchronous function is). Results and errors
   are the synchronous functions'; a timeout set with `hostSetIoTimeout` bounds the wait as it
   bounds the blocking read, and a stopped listener ends an async accept as it ends a blocking one.
   On POSIX the try-ops pass `MSG_DONTWAIT`. Winsock has no per-call flag and `FIONBIO` belongs
   to the socket, so switching it for one call and back would race with another task using the
   same connection: the first try-op leaves the connection non-blocking, and the blocking read and
   write wait in `WSAPoll` (bounded by the socket's timeout) when a call would block, so they
   behave the same in either mode. One try-write copies and sends at most 64 KiB
   (`LYRIC_SOCK_TRY_WRITE_CHUNK`), so a large write to a slow peer costs linear copying.
6. **Evidence.** `lyric_async_mt_test.c` parks 256 tasks on pipes written only after every task
   has parked, mixes reactor timeouts with sleepers, checks that busy threads still poll, and runs
   both schedulers, plain and under ThreadSanitizer and AddressSanitizer.
   `scripts/ci/async-io-e2e.sh` serves 1000 idle TCP connections from an `async` echo server
   (`lyric-stdlib/tests/async_echo_main.l`) at `LYRIC_ASYNC_THREADS=2` and with the cooperative
   scheduler, then 200 under ThreadSanitizer and AddressSanitizer.

## Not in this decision

- **TLS connections, `hostConnect` and `Std.File`** keep their blocking paths inside coroutines.
  A readable socket does not mean a TLS record is complete, connect and name resolution need a
  non-blocking connect and an offload for `getaddrinfo`, and a regular file is always "ready" to
  `poll`, so file I/O needs a blocking-offload pool rather than readiness. All three are #8811.
- **`when:` barrier waits** still hold their thread (D217 item 7).
- The process leaf keeps its 1 ms pump: its pipes could wait on the reactor through `waitFd2`, which
  is a follow-up of #8811's offload work rather than of readiness.
- wasm32 has no reactor: the leaf panics there, and the WASI socket and file kernels are
  unsupported stubs already.
