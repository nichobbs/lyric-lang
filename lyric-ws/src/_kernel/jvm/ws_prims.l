//! Ws.Kernel.Net primitives (JVM) — `ReentrantLock` locks, virtual-thread
//! background tasks, sleep and handler crash isolation for the RFC 6455
//! server in `_kernel/net/ws_kernel.l` that `dotnet`, `jvm` and `native`
//! share (docs/73 slice S7a, replacing the earlier JVM `Ws.startServer` kernel).
//! The dotnet and native twins (`_kernel/net/ws_prims.l`,
//! `_kernel/native/ws_prims.l`) declare the same names in the same package.
//!
//! * **Locks.** A `WsLock` wraps a `java.util.concurrent.locks.ReentrantLock`,
//!   not a `synchronized` monitor: a virtual thread blocked in `synchronized`
//!   pins its carrier on JDK 21, while a thread parked on a `ReentrantLock`
//!   does not (`Std.HttpServerHost` and `_kernel_jvm/task.l` make the same
//!   choice). A connection holds its lock across a socket write, so this
//!   matters for a server with many connections.
//! * **Threads.** `runBackground` starts a virtual thread. A Lyric closure
//!   reaches `Thread.startVirtualThread` through a record that implements
//!   `java.lang.Runnable` (docs/51).
//! * **Dictionary.** `ConcurrentDict` is the pure-Lyric lock-guarded map in
//!   `_kernel/net/ws_dict.l`, shared with native.
//!
//! Extern aliases carry a `J` prefix: the `dotnet` twin declares `extern type
//! ConcurrentDict` and `Task` for other host types, and a same-named alias in
//! two files of one package leaks across `@cfg` selections on this target
//! (#5443).
//!
//! Only active when compiled with feature = "jvm".
@cfg(feature = "jvm")
@io
package Ws.Kernel.Net

import Std.Core
import Std.Collections
import Std.TcpHost

extern type JWsLock = "java.util.concurrent.locks.ReentrantLock"

extern type JWsThread = "java.lang.Thread"

extern type JWsRunnable = "java.lang.Runnable"

// ─── Locks ───────────────────────────────────────────────────────────────────
/// A mutual-exclusion lock, reentrant and held per thread.
pub record WsLock {
  inner: JWsLock
}

pub func newWsLock(): WsLock {
  WsLock(inner = JWsLock.new())
}

pub func lockEnter(l: in WsLock): Unit {
  l.inner.lock()
}

pub func lockExit(l: in WsLock): Unit {
  l.inner.unlock()
}

/// Return a lock to the pool. A no-op here: the JVM reclaims it.
pub func releaseWsLock(l: in WsLock): Unit {
  ()
}

// ─── Threads and sleep ───────────────────────────────────────────────────────
record BackgroundJob {
  work: () -> Unit
}

impl JWsRunnable for BackgroundJob {
  func run(): Unit {
    self.work()
  }
}

/// Run `work` on its own virtual thread, fire-and-forget. A panic in `work`
/// ends only that thread.
pub func runBackground(work: in () -> Unit): Unit {
  val t: JWsThread = JWsThread.startVirtualThread(BackgroundJob(work = work));
  ()
}

func threadSleep(ms: in Int): Unit {
  JWsThread.sleep(ms.toLong())
}

/// Nothing to do on the JVM: each connection runs on a virtual thread.
func ensureThreadCapacity(): Unit {
  ()
}

// ─── Handler crash isolation ─────────────────────────────────────────────────
// Each returns the failure message when the callback panicked, `None` when it
// ran to completion.
func guardOnOpen(
  cb: in (String, String, String, String, Map[String, String]) -> Unit,
  connId: in String,
  path: in String,
  query: in String,
  remoteAddress: in String,
  headers: in Map[String, String],
): Option[String] {
  try {
    cb(connId, path, query, remoteAddress, headers)
    None
  } catch Bug as e {
    Some(value = e.message)
  }
}

func guardOnMessage(
  cb: in (String, String, String) -> Unit, connId: in String, msgType: in String, data: in String
): Option[String] {
  try {
    cb(connId, msgType, data)
    None
  } catch Bug as e {
    Some(value = e.message)
  }
}

func guardOnClose(
  cb: in (String, Int, String) -> Unit, connId: in String, code: in Int, reason: in String
): Option[String] {
  try {
    cb(connId, code, reason)
    None
  } catch Bug as e {
    Some(value = e.message)
  }
}

func guardOnError(cb: in (String, String) -> Unit, connId: in String, message: in String): Option[String] {
  try {
    cb(connId, message)
    None
  } catch Bug as e {
    Some(value = e.message)
  }
}

// ─── Accept-loop policy ──────────────────────────────────────────────────────
/// Whether the accept loop carries on after `e`: a failed accept or bind ends it
/// (`hostStopListener` closed the listener, or it is gone), anything else is one
/// bad peer and is skipped.
func acceptShouldContinue(e: in TcpError): Bool {
  match e {
    case AcceptFailed(_) -> false
    case BindFailed(_) -> false
    case _ -> true
  }
}
