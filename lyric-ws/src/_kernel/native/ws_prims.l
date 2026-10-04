//! Ws.Kernel.Net primitives (native) — pthread-backed locks, a mutex-guarded
//! dictionary, detached background threads and sleep, for the RFC 6455 server
//! in `_kernel/net/ws_kernel.l` that `dotnet` and `native` share. The dotnet
//! twin (`_kernel/net/ws_prims.l`) declares the same names in the same package.
//!
//! * **Locks.** A `WsLock` is a lyric-rt mutex. Mutexes come from a pool
//!   (`newWsLock` / `releaseWsLock`) so a connection's lock is recycled when it
//!   closes instead of leaking for the life of the process. A released lock
//!   that a stale reference still locks is harmless: it only serialises two
//!   unrelated users until one unlocks, and the pool never frees the memory.
//! * **Dictionary.** `ConcurrentDict` is a `Map` behind one lock; a reader or
//!   writer holds it only for the lookup, never across I/O.
//! * **Threads.** `runBackground` starts a detached `pthread` through
//!   `lyric_thread_spawn_detached`, which releases the closure when the thread
//!   ends (`Std.HttpServer`'s native kernel joins its threads at `stopListener`;
//!   a WebSocket connection thread has no such owner).
//!
//! Only active when compiled with feature = "native".
@cfg(feature = "native")
@io
package Ws.Kernel.Net

import Std.Core
import Std.Collections
import Std.TcpHost
import Std.TimeHost

@axiom("lyric_mutex_* and lyric_thread_spawn_detached (lyric-rt/src/lyric_posix.c; pthread on POSIX hosts), lyric_malloc_raw, and lyric_retain/lyric_release conform to their documented contracts")
extern func rtMallocRaw(n: Long): NativePtr[Byte] = "lyric_malloc_raw"

extern func rtMutexSize(): Int = "lyric_mutex_size"

extern func rtMutexInitRaw(m: NativePtr[Byte]): Unit = "lyric_mutex_init"

extern func rtMutexLockRaw(m: NativePtr[Byte]): Unit = "lyric_mutex_lock"

extern func rtMutexUnlockRaw(m: NativePtr[Byte]): Unit = "lyric_mutex_unlock"

extern func rtPtrToLong(p: NativePtr[Byte]): Long = "lyric_ptr_to_long"

extern func rtLongToPtr(v: Long): NativePtr[Byte] = "lyric_long_to_ptr"

extern func rtRetain(p: NativePtr[Byte]): Unit = "lyric_retain"

extern func rtRelease(p: NativePtr[Byte]): Unit = "lyric_release"

extern func rtThreadSpawnDetached(start: (NativePtr[Byte]) -> NativePtr[Byte], arg: NativePtr[Byte]): Int = "lyric_thread_spawn_detached"

// ─── Locks ───────────────────────────────────────────────────────────────────
/// A mutual-exclusion lock: the address of a lyric-rt mutex buffer.
pub record WsLock {
  handle: Long
}

@unsafe_ffi
func newRawMutex(): Long {
  val m = rtPtrToLong(rtMallocRaw(rtMutexSize().toLong()))
  rtMutexInitRaw(rtLongToPtr(m))
  m
}

@unsafe_ffi
func rawLock(handle: in Long): Unit {
  rtMutexLockRaw(rtLongToPtr(handle))
}

@unsafe_ffi
func rawUnlock(handle: in Long): Unit {
  rtMutexUnlockRaw(rtLongToPtr(handle))
}

// The pool of idle mutex buffers, guarded by `lockPoolGuard`.
val lockPoolGuard: Long = newRawMutex()

val lockPoolIdle: List[Long] = newList()

pub func newWsLock(): WsLock {
  rawLock(lockPoolGuard)
  var handle = 0i64
  if lockPoolIdle.count > 0 {
    handle = lockPoolIdle[lockPoolIdle.count - 1]
    lockPoolIdle.removeAt(lockPoolIdle.count - 1)
  }
  rawUnlock(lockPoolGuard)
  if handle == 0i64 {
    handle = newRawMutex()
  }
  WsLock(handle = handle)
}

pub func lockEnter(l: in WsLock): Unit {
  rawLock(l.handle)
}

pub func lockExit(l: in WsLock): Unit {
  rawUnlock(l.handle)
}

/// Return a lock to the pool once its owner is finished with it.
pub func releaseWsLock(l: in WsLock): Unit {
  rawLock(lockPoolGuard)
  lockPoolIdle.add(l.handle)
  rawUnlock(lockPoolGuard)
}

// ─── Concurrent dictionary ───────────────────────────────────────────────────
record ConcurrentDict[K, V] {
  lock: WsLock
  items: Map[K, V]
}

func newConcurrentDict[K, V](): ConcurrentDict[K, V] {
  val items: Map[K, V] = newMap()
  ConcurrentDict(lock = newWsLock(), items = items)
}

func cdTryGetValue[K, V](dict: in ConcurrentDict[K, V], key: in K, value: out V): Bool {
  lockEnter(dict.lock)
  defer {
    lockExit(dict.lock)
  }
  match mapGet(dict.items, key) {
    case Some(found) -> {
      value = found
      true
    }
    case None -> false
  }
}

func cdTryAdd[K, V](dict: in ConcurrentDict[K, V], key: in K, value: in V): Bool {
  lockEnter(dict.lock)
  defer {
    lockExit(dict.lock)
  }
  if dict.items.containsKey(key) {
    return false
  }
  dict.items.add(key, value)
  true
}

func cdTryRemove[K, V](dict: in ConcurrentDict[K, V], key: in K, value: out V): Bool {
  lockEnter(dict.lock)
  defer {
    lockExit(dict.lock)
  }
  match mapGet(dict.items, key) {
    case Some(found) -> {
      value = found
      val _ = dict.items.remove(key)
      true
    }
    case None -> false
  }
}

// ─── Threads and sleep ───────────────────────────────────────────────────────
/// Run `work` on its own detached thread, fire-and-forget. The closure is
/// retained across the spawn and released by the runtime when the thread ends.
@unsafe_ffi
pub func runBackground(work: in () -> Unit): Unit {
  val worker: () -> NativePtr[Byte] = { -> work(); nativeNullPtr() }
  rtRetain(worker)
  val rc = rtThreadSpawnDetached(worker, worker)
  if rc != 0 {
    rtRelease(worker)
    panic("Ws.Kernel.Net: could not start a background thread (errno " + rc.toString() + ")")
  }
}

func threadSleep(ms: in Int): Unit {
  hostSleepMillis(ms)
}

// ─── Handler crash isolation ─────────────────────────────────────────────────
// Native has no unwinding (D-N-003): a callback that panics ends the process,
// so there is no failure to catch and each call runs the callback directly.
func guardOnOpen(
  cb: in (String, String, String, String, Map[String, String]) -> Unit,
  connId: in String,
  path: in String,
  query: in String,
  remoteAddress: in String,
  headers: in Map[String, String],
): Option[String] {
  cb(connId, path, query, remoteAddress, headers)
  None
}

func guardOnMessage(cb: in (String, String, String) -> Unit, connId: in String, msgType: in String, data: in String): Option[String] {
  cb(connId, msgType, data)
  None
}

func guardOnClose(cb: in (String, Int, String) -> Unit, connId: in String, code: in Int, reason: in String): Option[String] {
  cb(connId, code, reason)
  None
}

func guardOnError(cb: in (String, String) -> Unit, connId: in String, message: in String): Option[String] {
  cb(connId, message)
  None
}

// ─── Accept-loop policy ──────────────────────────────────────────────────────
/// Whether the accept loop carries on after `e`. Native classifies an accept
/// failure (`AcceptFailureKind`): a fatal one ends the loop (the listener is
/// gone, including `hostStopListener`'s wake), a transient one is retried at
/// once, and descriptor exhaustion backs off briefly so the loop does not spin.
func acceptShouldContinue(e: in TcpError): Bool {
  match e {
    case AcceptFailed(_, _, kind) -> match kind {
      case AcceptFatal -> false
      case AcceptTransient -> true
      case AcceptOverloaded -> {
        threadSleep(50)
        true
      }
    }
    case BindFailed(_) -> false
    case _ -> true
  }
}
