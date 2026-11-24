//! `Std.HttpServerHost` (native kernel): the per-target concurrency seam of the
//! shared HTTP server driver (docs/73 section 1.2, slice S2, D786). The
//! package, its public surface and its contracts are documented in the dotnet
//! twin, `_kernel/http_server_host.l`; this file implements them over the
//! lyric-rt primitives `_kernel_native/http_server.l` already uses:
//! `lyric_mutex_*` (reentrant), `lyric_sem_*`, `lyric_thread_create` /
//! `lyric_thread_join` and `lyric_thread_spawn_detached`.
//!
//! Native has no unwinding (D-N-003), so `runGuarded` is a direct call and a
//! panic ends the process.
//!
//! **Closure lifetime (#6797).** A closure handed to a thread outlives the
//! spawning frame, whose scope-exit release would otherwise free it while the
//! new thread still reads its environment. Every spawn here retains the
//! closure first. `startTask` uses `lyric_thread_spawn_detached`, whose
//! thread releases that retain when its body returns; `workerAdd` uses
//! `lyric_thread_create` and keeps the retained pointer (as a `Long`, because
//! a `NativePtr` record field is rejected by N0100) next to the tid, releasing
//! it only after `workerJoinAll` has joined that thread. A failed spawn
//! releases the retain at once, since no thread will.
@axiom("lyric_mutex_*/lyric_sem_* (lyric-rt/src/lyric_posix.c), lyric_thread_create/lyric_thread_join/lyric_thread_spawn_detached (lyric-rt; pthread on POSIX hosts), lyric_retain/lyric_release (the ARC primitives) and malloc/free conform to their documented contracts")
@io
package Std.HttpServerHost

import Std.Core
import Std.Collections
import Std.TcpHost

extern func rtMallocRaw(n: Long): NativePtr[Byte] = "lyric_malloc_raw"

extern func rtFreeRaw(p: NativePtr[Byte]): Unit = "free"

extern func rtPtrToLong(p: NativePtr[Byte]): Long = "lyric_ptr_to_long"

extern func rtLongToPtr(v: Long): NativePtr[Byte] = "lyric_long_to_ptr"

extern func rtMutexSize(): Int = "lyric_mutex_size"

extern func rtMutexInitRaw(m: NativePtr[Byte]): Unit = "lyric_mutex_init"

extern func rtMutexLockRaw(m: NativePtr[Byte]): Unit = "lyric_mutex_lock"

extern func rtMutexUnlockRaw(m: NativePtr[Byte]): Unit = "lyric_mutex_unlock"

extern func rtMutexDestroyRaw(m: NativePtr[Byte]): Unit = "lyric_mutex_destroy"

extern func rtSemSize(): Int = "lyric_sem_size"

extern func rtSemInitRaw(s: NativePtr[Byte], initial: Int): Unit = "lyric_sem_init"

extern func rtSemWaitRaw(s: NativePtr[Byte]): Unit = "lyric_sem_wait"

extern func rtSemTryWaitRaw(s: NativePtr[Byte]): Int = "lyric_sem_trywait"

extern func rtSemPostRaw(s: NativePtr[Byte]): Unit = "lyric_sem_post"

extern func rtSemDestroyRaw(s: NativePtr[Byte]): Unit = "lyric_sem_destroy"

extern func pthreadCreate(tid: NativePtr[Long], start: (NativePtr[Byte]) -> NativePtr[Byte], arg: NativePtr[Byte]): Int = "lyric_thread_create"

extern func pthreadJoin(tid: Long, retval: NativePtr[NativePtr[Byte]]): Int = "lyric_thread_join"

extern func rtThreadSpawnDetached(start: (NativePtr[Byte]) -> NativePtr[Byte], arg: NativePtr[Byte]): Int = "lyric_thread_spawn_detached"

extern func rtRetain(p: NativePtr[Byte]): Unit = "lyric_retain"

extern func rtRelease(p: NativePtr[Byte]): Unit = "lyric_release"

/// A no-op on native; the dotnet twin raises the thread pool minimum.
pub func ensureThreadCapacity(connections: in Int): Unit
  requires: connections >= 1
{
  ()
}

/// The cap on concurrently served connections when `LYRIC_HTTP_MAX_CONNECTIONS`
/// is unset: a connection is a pthread here, so 1000.
pub func defaultMaxConnections(): Int {
  1000
}

/// Run `work` on its own detached OS thread, fire-and-forget. The thread
/// releases the closure when `work` returns. `false` when the thread could not
/// be created (the retain is undone, nothing leaks).
@unsafe_ffi
pub func tryStartTask(work: in () -> Unit): Bool {
  val worker: () -> NativePtr[Byte] = { -> work(); nativeNullPtr() }
  rtRetain(worker)
  val rc = rtThreadSpawnDetached(worker, worker)
  if rc != 0 {
    rtRelease(worker)
    return false
  }
  true
}

/// Run `work` on its own detached OS thread, fire-and-forget. Panics if the
/// thread cannot be created; `tryStartTask` reports that as `false` instead.
@unsafe_ffi
pub func startTask(work: in () -> Unit): Unit {
  if not tryStartTask(work) {
    panic("Std.HttpServerHost.startTask: could not start a thread")
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

/// Classify a failed `hostAccept` by the portable `AcceptFailureKind` the
/// native transport attaches to it (issue #6805).
pub func acceptOutcome(e: in TcpError): AcceptOutcome {
  match e {
    case AcceptFailed(_, _, kind) -> match kind {
      case AcceptFatal -> AcceptStop
      case AcceptTransient -> AcceptRetry
      case AcceptOverloaded -> AcceptBackoff
    }
    case BindFailed(_) -> AcceptStop
    case _ -> AcceptRetry
  }
}

/// A reentrant mutual-exclusion lock over a malloc'd `lyric_mutex_*` slot.
pub ref record Mutex {
  handle: Long
}

pub func newMutex(): Mutex {
  val h = rtPtrToLong(rtMallocRaw(rtMutexSize().toLong()))
  rtMutexInitRaw(rtLongToPtr(h))
  Mutex(handle = h)
}

pub func lock(m: in Mutex): Unit {
  rtMutexLockRaw(rtLongToPtr(m.handle))
}

pub func unlock(m: in Mutex): Unit {
  rtMutexUnlockRaw(rtLongToPtr(m.handle))
}

/// Destroy and free the lock. No thread may hold or wait on it, and it must
/// not be used afterwards.
pub func releaseMutex(m: in Mutex): Unit {
  rtMutexDestroyRaw(rtLongToPtr(m.handle))
  rtFreeRaw(rtLongToPtr(m.handle))
}

/// A counting semaphore over a malloc'd `lyric_sem_*` slot.
pub ref record Semaphore {
  handle: Long
}

pub func newSem(initialCount: in Int): Semaphore {
  val h = rtPtrToLong(rtMallocRaw(rtSemSize().toLong()))
  rtSemInitRaw(rtLongToPtr(h), initialCount)
  Semaphore(handle = h)
}

/// Block until a credit is available, then take it.
pub func semWait(s: in Semaphore): Unit {
  rtSemWaitRaw(rtLongToPtr(s.handle))
}

/// Take a credit if one is available now; `false` and no wait otherwise.
pub func semTryWait(s: in Semaphore): Bool {
  rtSemTryWaitRaw(rtLongToPtr(s.handle)) == 1
}

/// Add one credit and wake one waiter.
pub func semPost(s: in Semaphore): Unit {
  rtSemPostRaw(rtLongToPtr(s.handle))
}

/// Destroy and free the semaphore. No thread may wait on it, and it must not
/// be used afterwards.
pub func releaseSem(s: in Semaphore): Unit {
  rtSemDestroyRaw(rtLongToPtr(s.handle))
  rtFreeRaw(rtLongToPtr(s.handle))
}

/// Run `work` directly: native cannot catch a panic, so `onFailure` is never
/// called.
pub func runGuarded(work: in () -> Unit, onFailure: in (String) -> Unit): Unit {
  work()
}

/// A set of tasks that can be joined together. `tids` and `closures` are
/// appended in one locked section so their indices stay paired.
pub ref record WorkerSet {
  guard: Mutex
  tids: List[Long]
  closures: List[Long]
}

pub func newWorkerSet(): WorkerSet {
  val tids: List[Long] = newList()
  val closures: List[Long] = newList()
  WorkerSet(guard = newMutex(), tids = tids, closures = closures)
}

/// Start `work` on its own OS thread as a member of `set`. `false` when the
/// thread could not be created (nothing was added, nothing leaks).
@unsafe_ffi
pub func workerAdd(set: in WorkerSet, work: in () -> Unit): Bool {
  var tid: Long = 0
  val worker: () -> NativePtr[Byte] = { -> work(); nativeNullPtr() }
  rtRetain(worker)
  val handle = rtPtrToLong(worker)
  val rc = pthreadCreate(nativeAddrOf(tid), worker, worker)
  if rc == 0 {
    lock(set.guard)
    set.tids.add(tid)
    set.closures.add(handle)
    unlock(set.guard)
    true
  } else {
    rtRelease(worker)
    false
  }
}

/// Block until every task added to `set` has finished, including tasks those
/// tasks add while this call waits, and release their closures. The set is
/// empty afterwards.
@unsafe_ffi
pub func workerJoinAll(set: in WorkerSet): Unit {
  var more = true
  while more {
    lock(set.guard)
    val tids = set.tids.toArray()
    val handles = set.closures.toArray()
    set.tids.clear()
    set.closures.clear()
    unlock(set.guard)
    if tids.length == 0 {
      more = false
    } else {
      var i = 0
      while i < tids.length {
        var outp: NativePtr[Byte] = nativeNullPtr()
        val _ = pthreadJoin(tids[i], nativeAddrOf(outp))
        rtRelease(rtLongToPtr(handles[i]))
        i = i + 1
      }
    }
  }
}

/// Free the set's lock. The set must be empty (joined) and not used again.
pub func releaseWorkerSet(set: in WorkerSet): Unit {
  releaseMutex(set.guard)
}
