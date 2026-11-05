# Native async scheduler: an I/O reactor, and non-blocking socket twins (#8494)

D405. A task inside an `async func` that waits on a socket no longer holds a scheduler thread:

- `lyric-rt/src/lyric_async.c` has a readiness reactor: `lyric_async_wait_fd` / `lyric_async_wait_fd2`
  park the running task on one or two descriptors with an optional timeout (two-phase registration,
  as for sleep), `lyric_async_wait_fd_result` reads the outcome, and `lyric_fd_wait` / `lyric_fd_wait2`
  are the blocking forms. The cooperative scheduler polls when nothing is ready instead of sleeping;
  the multi-threaded one lets one idle thread at a time block in the poll with the earliest deadline
  as timeout, interrupted through a wake pipe (a loopback socket pair on Windows) when work arrives,
  and busy threads poll without waiting every 61 tasks. `poll(2)` on Linux and macOS, `WSAPoll` on
  Windows. Deadlock detection counts parked descriptors as pending work.
- `Std.IoWait.waitFd` / `waitFd2` (`_kernel_native/io_wait.l`) block in `poll` when called
  synchronously; inside a coroutine the code generator lowers them to the reactor leaf.
- `Std.TcpHost` gains `hostAcceptAsync`, `hostReadAsync` and `hostWriteAsync` over new non-blocking
  runtime calls (`lyric_sock_try_accept`, `lyric_sock_try_read_bytes`, `lyric_sock_try_write_bytes`,
  `lyric_sock_io_timeout_ms`, POSIX and Winsock); an awaited `hostAccept` / `hostRead` / `hostWrite`
  inside a coroutine is lowered as its twin (`nativeAsyncTwin`, kept reachable by the bridge). A
  `hostSetIoTimeout` timeout and a stopped listener behave as on the blocking path.

Tests: `lyric_async_mt_test.c` adds reactor cases (256 pipes written after every task parked,
timeouts beside sleepers, polling while every thread is busy, the blocking form) and runs under the
cooperative scheduler as well (`LYRIC_ASYNC_THREADS=1`), plain, TSan and ASan.
`scripts/ci/async-io-e2e.sh` (native-platforms workflow, Linux arm64 and macOS) runs an `async` echo
server (`lyric-stdlib/tests/async_echo_main.l`) with 1000 idle connections at
`LYRIC_ASYNC_THREADS=2` and on the cooperative scheduler, and 200 under ThreadSanitizer and
AddressSanitizer. TLS connections, `hostConnect` and `Std.File` keep blocking (#8811).
