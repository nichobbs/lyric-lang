//! `Std.HttpServerHost` (dotnet kernel): the per-target concurrency seam of the
//! shared HTTP server driver (docs/73 section 1.2, slice S2, D786).
//!
//! The seam is the only part of the server driver that differs per target:
//! a fire-and-forget thread, a reentrant mutex, a counting semaphore, a
//! panic-isolating call and a joinable set of worker threads. Everything else
//! (accept loop, FIFO of ready contexts, connection loop, h2 scheduler,
//! limits) is shared Lyric over this surface. The three twins
//! (`_kernel/`, `_kernel_jvm/`, `_kernel_native/`) declare the same package
//! with the same public surface; nothing here is specific to HTTP, the name
//! only says who the first consumer is.
//!
//! | Seam | dotnet | JVM | native |
//! |---|---|---|---|
//! | `startTask` | `Task.Run` | virtual thread | detached `pthread` (`lyric_thread_spawn_detached`) |
//! | `Mutex` | `Monitor` (reentrant) | `ReentrantLock` | `lyric_mutex_*` (reentrant) |
//! | `Semaphore` | `SemaphoreSlim` | `java.util.concurrent.Semaphore` | `lyric_sem_*` |
//! | `runGuarded` | `try`/`catch Bug` | `try`/`catch Bug` | a direct call (no unwinding, D-N-003) |
//! | `WorkerSet` | tracked tasks, joined by a completion semaphore | same | `pthread_create` + `pthread_join` |
//!
//! Contracts every twin keeps (the shared tests, `http_server_host_tests.l`,
//! pin them on each target):
//!
//! - `Mutex` is reentrant: the holder may `lock` again and must `unlock` as
//!   many times.
//! - `Semaphore` is counting and fair to no particular waiter; `semPost` before
//!   `semWait` is not lost.
//! - `workerJoinAll` returns only after every task added to the set before the
//!   call, and every task those tasks added to the same set, has finished its
//!   work. After it returns the set is empty and may be reused.
//! - A task started with `workerAdd` that panics still counts as finished, so
//!   `workerJoinAll` never waits for it forever (dotnet and JVM; on native a
//!   panic ends the process).
//! - `runGuarded` reports a panic raised by `work` to `onFailure` (dotnet and
//!   JVM). On native the panic ends the process, `onFailure` is never called.
//!
//! This file is the dotnet kernel and therefore may contain `extern type` and
//! `@externTarget` declarations (docs/14, Decision F).
@axiom("System.Threading.Tasks.Task.Run, System.Threading.Monitor, System.Threading.ThreadPool.SetMinThreads and System.Threading.SemaphoreSlim operations conform to their documented .NET contracts")
@io
package Std.HttpServerHost

import Std.Core

@sendable
extern type Task = "System.Threading.Tasks.Task"

@externStatic
@externTarget("System.Threading.Tasks.Task.Run")
func taskRun(work: in () -> Unit): Task = ()

@externStatic
@externTarget("System.Threading.Monitor.Enter")
func monitorEnter[T](obj: in T): Unit = ()

@externStatic
@externTarget("System.Threading.Monitor.Exit")
func monitorExit[T](obj: in T): Unit = ()

@externStatic
@externTarget("System.Threading.ThreadPool.SetMinThreads")
func setMinThreads(workerThreads: in Int, completionPortThreads: in Int): Bool = ()

@sendable
pub extern type Semaphore = "System.Threading.SemaphoreSlim"

@externTarget("System.Threading.SemaphoreSlim..ctor")
func newSemaphore(initialCount: in Int): Semaphore = ()

@externInstance
@externTarget("System.Threading.SemaphoreSlim.Wait")
func semaphoreWait(s: in Semaphore): Unit = ()

@externInstance
@externTarget("System.Threading.SemaphoreSlim.Wait")
func semaphoreWaitMs(s: in Semaphore, millisecondsTimeout: in Int): Bool = ()

@externInstance
@externTarget("System.Threading.SemaphoreSlim.Release")
func semaphoreRelease(s: in Semaphore): Int = ()

/// Raise the thread pool's minimum so a server that parks one pool thread per
/// connection is not throttled by the pool's slow thread injection. Call once
/// before the first `startTask`. A no-op on the JVM and native.
pub func ensureThreadCapacity(): Unit {
  val _ = setMinThreads(200, 200);
  ()
}

/// Run `work` on its own thread, fire-and-forget. A panic in `work` ends only
/// that task; wrap `work` in `runGuarded` to observe it.
pub func startTask(work: in () -> Unit): Unit {
  val _ = taskRun(work);
  ()
}

/// A reentrant mutual-exclusion lock, held per thread.
pub ref record Mutex {
  tag: Int
}

pub func newMutex(): Mutex {
  Mutex(tag = 0)
}

pub func lock(m: in Mutex): Unit {
  monitorEnter(m)
}

pub func unlock(m: in Mutex): Unit {
  monitorExit(m)
}

/// Free the lock. A no-op here: the CLR reclaims it.
pub func releaseMutex(m: in Mutex): Unit {
  ()
}

/// A counting semaphore with `initialCount` credits.
pub func newSem(initialCount: in Int): Semaphore {
  newSemaphore(initialCount)
}

/// Block until a credit is available, then take it.
pub func semWait(s: in Semaphore): Unit {
  semaphoreWait(s)
}

/// Take a credit if one is available now; `false` and no wait otherwise.
pub func semTryWait(s: in Semaphore): Bool {
  semaphoreWaitMs(s, 0)
}

/// Add one credit and wake one waiter.
pub func semPost(s: in Semaphore): Unit {
  val _ = semaphoreRelease(s);
  ()
}

/// Free the semaphore. A no-op here: the CLR reclaims it.
pub func releaseSem(s: in Semaphore): Unit {
  ()
}

/// Run `work`; if it panics, hand the panic message to `onFailure` and return
/// normally.
pub func runGuarded(work: in () -> Unit, onFailure: in (String) -> Unit): Unit {
  try {
    work()
  } catch Bug as e {
    onFailure(e.message)
  }
}

/// A set of tasks that can be waited for together. `pending` counts tasks
/// started and not yet joined; each finished task posts one credit to `done`.
pub ref record WorkerSet {
  guard: Mutex
  done: Semaphore
  var pending: Int
}

pub func newWorkerSet(): WorkerSet {
  WorkerSet(guard = newMutex(), done = newSem(0), pending = 0)
}

/// Start `work` on its own thread as a member of `set`. `true` when the thread
/// started.
pub func workerAdd(set: in WorkerSet, work: in () -> Unit): Bool {
  lock(set.guard)
  set.pending = set.pending + 1
  unlock(set.guard)
  startTask({ -> defer { semPost(set.done) }; work() })
  true
}

/// Block until every task added to `set` has finished, including tasks those
/// tasks add while this call waits. The set is empty afterwards.
pub func workerJoinAll(set: in WorkerSet): Unit {
  var more = true
  while more {
    lock(set.guard)
    val n = set.pending
    set.pending = 0
    unlock(set.guard)
    if n == 0 {
      more = false
    } else {
      var i = 0
      while i < n {
        semWait(set.done)
        i = i + 1
      }
    }
  }
}

/// Free the set. A no-op here: the CLR reclaims it.
pub func releaseWorkerSet(set: in WorkerSet): Unit {
  ()
}
