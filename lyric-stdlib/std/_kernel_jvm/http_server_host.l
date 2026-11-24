//! `Std.HttpServerHost` (JVM kernel): the per-target concurrency seam of the
//! shared HTTP server driver (docs/73 section 1.2, slice S2, D786). The
//! package, its public surface and its contracts are documented in the dotnet
//! twin, `_kernel/http_server_host.l`; this file implements them over
//! `java.lang.Thread` virtual threads, `ReentrantLock` and
//! `java.util.concurrent.Semaphore`.
//!
//! `ReentrantLock` and not `synchronized`: a virtual thread blocked in a
//! `synchronized` block pins its carrier thread on JDK 21, so a server with
//! many connections parked on the queue lock could starve the scheduler
//! (`_kernel_jvm/task.l` makes the same choice). A plain record implements
//! `java.lang.Runnable` through an `impl` block (docs/51), which is how a
//! Lyric closure reaches `Thread.startVirtualThread`.
@axiom("java.lang.Thread.startVirtualThread, java.util.concurrent.locks.ReentrantLock and java.util.concurrent.Semaphore operations conform to their documented JVM contracts")
@io
package Std.HttpServerHost

import Std.Core
import Std.TcpHost

extern type JThread = "java.lang.Thread"

extern type JRunnable = "java.lang.Runnable"

pub extern type Mutex = "java.util.concurrent.locks.ReentrantLock"

pub extern type Semaphore = "java.util.concurrent.Semaphore"

record StartJob {
  work: () -> Unit
}

impl JRunnable for StartJob {
  func run(): Unit {
    self.work()
  }
}

/// A no-op on the JVM; the dotnet twin raises the thread pool minimum.
pub func ensureThreadCapacity(connections: in Int): Unit
  requires: connections >= 1
{
  ()
}

/// The cap on concurrently served connections when `LYRIC_HTTP_MAX_CONNECTIONS`
/// is unset: a connection is a virtual thread here, which costs a few KiB
/// parked, so 10000 (D780: 10 000 idle connections held in about 260 MB).
pub func defaultMaxConnections(): Int {
  10000
}

/// Run `work` on its own virtual thread, fire-and-forget. A panic in `work`
/// ends only that thread; wrap `work` in `runGuarded` to observe it. Panics if
/// the thread cannot be started (`tryStartTask` reports that as `false`).
pub func startTask(work: in () -> Unit): Unit {
  if not tryStartTask(work) {
    panic("Std.HttpServerHost.startTask: could not start a thread")
  }
}

/// `startTask` that reports a thread that could not be created as `false`: a
/// JVM that is out of memory or native threads fails `startVirtualThread` with
/// an `Error` rather than queueing the work, and the server's accept loop turns
/// `false` into one refused connection instead of a dead listener.
pub func tryStartTask(work: in () -> Unit): Bool {
  try {
    val t: JThread = JThread.startVirtualThread(StartJob(work = work))
    true
  } catch Bug as _ {
    false
  }
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
pub func newMutex(): Mutex {
  Mutex.new()
}

pub func lock(m: in Mutex): Unit {
  m.lock()
}

pub func unlock(m: in Mutex): Unit {
  m.unlock()
}

/// Free the lock. A no-op here: the JVM reclaims it.
pub func releaseMutex(m: in Mutex): Unit {
  ()
}

/// A counting semaphore with `initialCount` credits.
pub func newSem(initialCount: in Int): Semaphore {
  Semaphore.new(initialCount)
}

/// Block until a credit is available, then take it.
pub func semWait(s: in Semaphore): Unit {
  s.acquire()
}

/// Take a credit if one is available now; `false` and no wait otherwise.
pub func semTryWait(s: in Semaphore): Bool {
  s.tryAcquire()
}

/// Add one credit and wake one waiter.
pub func semPost(s: in Semaphore): Unit {
  s.release()
}

/// Free the semaphore. A no-op here: the JVM reclaims it.
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

/// Start `work` on its own virtual thread as a member of `set`. `true` when
/// the thread started.
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

/// Free the set. A no-op here: the JVM reclaims it.
pub func releaseWorkerSet(set: in WorkerSet): Unit {
  ()
}
