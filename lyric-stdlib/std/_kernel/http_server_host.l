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
//! | `startTask`, `tryStartTask` | `Task.Run` | virtual thread | detached `pthread` (`lyric_thread_spawn_detached`) |
//! | `Mutex` | `Monitor` (reentrant) | `ReentrantLock` | `lyric_mutex_*` (reentrant) |
//! | `Semaphore` | `SemaphoreSlim` | `java.util.concurrent.Semaphore` | `lyric_sem_*` |
//! | `runGuarded` | `try`/`catch Bug` | `try`/`catch Bug` | a direct call (no unwinding, D-N-003) |
//! | `WorkerSet` | tracked tasks, joined by a completion semaphore | same | `pthread_create` + `pthread_join` |
//! | `acceptOutcome` | `AcceptFailed`/`BindFailed` end the loop | same | the `AcceptFailureKind` of the failure |
//! | `defaultMaxConnections` | 1000 (one pool thread per connection) | 10000 (virtual threads) | 1000 (one pthread per connection) |
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
//! - `tryStartTask` is `startTask` that reports a thread that could not be
//!   created as `false` instead of a panic. A server's accept loop uses it so
//!   running out of threads refuses one connection and keeps serving; on dotnet
//!   and the JVM it is always `true` (the pool and the virtual-thread scheduler
//!   queue the work, they do not fail to start).
//!
//! This file is the dotnet kernel and therefore may contain `extern type` and
//! `@externTarget` declarations (docs/14, Decision F).
@axiom("System.Threading.Tasks.Task.Run, System.Threading.Monitor, System.Threading.ThreadPool.SetMinThreads and System.Threading.SemaphoreSlim operations conform to their documented .NET contracts")
@io
package Std.HttpServerHost

import Std.Core
import Std.TcpHost

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

/// Raise the thread pool's minimum so a server that parks pool threads per
/// connection is not throttled by the pool's slow thread injection (about one
/// new thread every 500 ms past the minimum, which left every connection past
/// the first few hundred unserved under a large idle population, D780). A
/// connection holds one pool thread, an h2 connection two, so the minimum is
/// twice `connections` plus headroom for the accept loop and the caller's own
/// tasks, never below 200. Raising the minimum allocates nothing: threads are
/// still created on demand, only without the throttle. Call once before the
/// first `startTask`. A no-op on the JVM and native.
pub func ensureThreadCapacity(connections: in Int): Unit
  requires: connections >= 1
{
  val wanted = connections * 2 + 64
  val workers = if wanted < 200 { 200 } else { wanted }
  val _ = setMinThreads(workers, 200);
  ()
}

/// The cap on concurrently served connections when `LYRIC_HTTP_MAX_CONNECTIONS`
/// is unset: each connection costs a pool thread here, so 1000.
pub func defaultMaxConnections(): Int {
  1000
}

/// Run `work` on its own thread, fire-and-forget. A panic in `work` ends only
/// that task; wrap `work` in `runGuarded` to observe it.
pub func startTask(work: in () -> Unit): Unit {
  val _ = taskRun(work);
  ()
}

/// `startTask` that reports a thread that could not be created as `false`.
/// Always `true` here.
pub func tryStartTask(work: in () -> Unit): Bool {
  val _ = taskRun(work)
  true
}

/// What a server's accept loop does with one failed accept.
pub union AcceptOutcome {
  /// The listening socket is gone (the loop ends).
  case AcceptStop
  /// A failure of one connection (the loop goes on at once).
  case AcceptRetry
  /// Resource exhaustion, such as no file descriptors left (the loop goes on
  /// after a short pause).
  case AcceptBackoff
}

/// Classify a failed `hostAccept`. Here a failed accept or bind ends the loop,
/// anything else keeps it going.
pub func acceptOutcome(e: in TcpError): AcceptOutcome {
  match e {
    case AcceptFailed(_) -> AcceptStop
    case BindFailed(_) -> AcceptStop
    case _ -> AcceptRetry
  }
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
