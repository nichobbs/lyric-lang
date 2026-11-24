# D786 - `Std.HttpServerHost`, the per-target concurrency seam of the shared HTTP server driver (docs/73 slice S2)

**Status:** accepted. Extends D780 (S0) and D621 (S1); supersedes nothing. The id is the next free one on `main` at the time of writing (D785 was the highest); the S3 to S5 decisions the plan numbers D615 to D618 take later ids.

## Context

docs/73 section 1.2 splits the shared server driver from the few operations that differ per target. S0's spike (a) proved the package split on dotnet, the JVM and native with a reduced two-function seam. S2 ships the real seam, with nothing consuming it yet (S3 does).

## Decision

1. **Package `Std.HttpServerHost`**, three twins with one public surface: `lyric-stdlib/std/_kernel/http_server_host.l` (dotnet), `_kernel_jvm/http_server_host.l`, `_kernel_native/http_server_host.l`. Registered in `lyric-stdlib/lyric.full.toml` before `Std.HttpServer`; the JVM and native source loaders pick it up with no change.
2. **Surface.** `startTask(work)`; `Mutex` with `newMutex`, `lock`, `unlock`, `releaseMutex`; `Semaphore` with `newSem(n)`, `semWait`, `semTryWait`, `semPost`, `releaseSem`; `runGuarded(work, onFailure)`; `WorkerSet` with `newWorkerSet`, `workerAdd(set, work): Bool`, `workerJoinAll`, `releaseWorkerSet`; and `ensureThreadCapacity()`.
3. **Names where docs/73 was ambiguous.** The plan lists `release` for both `Mutex` and `Semaphore`; Lyric has no overloading, so they are `releaseMutex` and `releaseSem` (as `releaseWsLock` in lyric-ws). The semaphore type is `Semaphore` and its constructor `newSem`, as the spike. `ensureThreadCapacity` carries the dotnet `ThreadPool.SetMinThreads(200, 200)` the plan names as "plus ensureServerThreadCapacity"; it is a no-op on the JVM and native. No timed semaphore wait: the plan allows keeping the dotnet 100 ms slice polling for the h2 drain watchdog, and native has no timed `lyric_sem_*`.
4. **Contracts every twin keeps**, each pinned by a test on every target: `Mutex` is reentrant (`Monitor`, `ReentrantLock`, the lyric-rt monitor); `Semaphore` is counting and a post before a wait is not lost; `semTryWait` never blocks.
5. **`WorkerSet` really joins on every target**, not only native. `workerJoinAll` returns after every task added before the call and every task those tasks add meanwhile, and leaves the set reusable. dotnet and the JVM count started tasks under a mutex and consume one completion credit per task (posted from a `defer`, so a panicking task still counts); native keeps a tid and a retained closure pointer per thread and `pthread_join`s them. The plan said dotnet/JVM could no-op; a real join costs a semaphore and lets the shared driver and its tests rely on one behaviour.
6. **`runGuarded`** is `try`/`catch Bug` on dotnet and the JVM and a direct call on native (D-N-003): there a panic ends the process and `onFailure` is never called.
7. **Native reuses lyric-rt.** `startTask` is `lyric_thread_spawn_detached` (the runtime releases the retained closure when the thread ends, the path `Std.Task` already uses); `workerAdd` is `lyric_thread_create` with the closure retained before the call and its pointer kept as a `Long` until the join (the #6797 discipline); a failed create releases the retain and returns `false`. Mutex and semaphore are malloc'd `lyric_mutex_*`/`lyric_sem_*` slots freed by `release*`. No lyric-rt change.

## Verification

`lyric-stdlib/tests/http_server_host_tests.l` (12 tests) passes on dotnet, the JVM and native. The panic cases are compiled out on native with `@cfg(target = "native")`. A mutation run (the lock calls removed from the mutual-exclusion test) fails on dotnet and the JVM, so that test does detect a missing lock. An AddressSanitizer build of a native driver (20 rounds of 64 workers, 2000 detached tasks, closures handed over from returned frames, all released) reports no error or leak. Wired into `scripts/ci/stdlib-net-tests.sh` (dotnet, JVM) and `scripts/ci/native-platform-tests.sh` / `native-backend-self-tests.sh` (native). Not added to the Windows native list: untested there.
