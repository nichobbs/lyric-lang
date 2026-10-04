//! Ws.Kernel.Net primitives (dotnet) — the BCL-backed locks, concurrent
//! dictionary, background tasks and sleep `ws_kernel.l` builds on.
//!
//! `ws_kernel.l` (the RFC 6455 server) is shared by `dotnet` and `native`; the
//! few operations that differ per target live in this file and its native twin
//! (`_kernel/native/ws_prims.l`), which declare the same names in the same
//! package so the shared file compiles unchanged against either.
//!
//! Only active when compiled with feature = "dotnet".
//! See docs/14-native-stdlib-plan.md for the kernel boundary contract.
@cfg(feature = "dotnet")
@io
package Ws.Kernel.Net

import Std.Core
import Std.Collections
import Std.TcpHost

extern type ConcurrentDict[K, V] = "System.Collections.Concurrent.ConcurrentDictionary`2"

@externTarget("System.Collections.Concurrent.ConcurrentDictionary`2..ctor")
func newConcurrentDict[K, V](): ConcurrentDict[K, V] = ()

@externTarget("System.Collections.Concurrent.ConcurrentDictionary`2.TryGetValue")
func cdTryGetValue[K, V](dict: in ConcurrentDict[K, V], key: in K, value: out V): Bool = ()

@externTarget("System.Collections.Concurrent.ConcurrentDictionary`2.TryAdd")
func cdTryAdd[K, V](dict: in ConcurrentDict[K, V], key: in K, value: in V): Bool = ()

@externTarget("System.Collections.Concurrent.ConcurrentDictionary`2.TryRemove")
func cdTryRemove[K, V](dict: in ConcurrentDict[K, V], key: in K, value: out V): Bool = ()

@axiom("System.Threading.Monitor.Enter — acquires an exclusive lock on obj")
@externStatic
@externTarget("System.Threading.Monitor.Enter")
func monitorEnter[T](obj: in T): Unit = ()

@axiom("System.Threading.Monitor.Exit — releases an exclusive lock on obj")
@externStatic
@externTarget("System.Threading.Monitor.Exit")
func monitorExit[T](obj: in T): Unit = ()

// `Task.Run(Action)` gives a background OS thread for the accept loop and
// each connection's read/ping loops — the same primitive `_kernel/
// http_server.l` uses, for the same reason (`spawn` is degenerate-
// synchronous on this target).
extern type Task = "System.Threading.Tasks.Task"

@externStatic
@externTarget("System.Threading.Tasks.Task.Run")
func taskRun(work: in () -> Unit): Task = ()

@externStatic
@externTarget("System.Threading.Thread.Sleep")
func threadSleep(ms: in Int): Unit = ()

/// A mutual-exclusion lock: the object a `Monitor` is taken on.
pub record WsLock {
}

pub func newWsLock(): WsLock {
  WsLock()
}

pub func lockEnter(l: in WsLock): Unit {
  monitorEnter(l)
}

pub func lockExit(l: in WsLock): Unit {
  monitorExit(l)
}

/// Return a lock to the pool. A no-op here: the CLR reclaims it.
pub func releaseWsLock(l: in WsLock): Unit {
  ()
}

/// Run `work` on its own thread, fire-and-forget.
pub func runBackground(work: in () -> Unit): Unit {
  val _ = taskRun(work)
}

// ─── Handler crash isolation ─────────────────────────────────────────────────
// Each returns the failure message when the callback threw, `None` when it ran
// to completion.
func guardOnOpen(
  cb: in (String, String, String, String, Map[String, String]) -> Unit,
  connId: in String,
  path: in String,
  query: in String,
  remoteAddress: in String,
  headers: in Map[String, String],
): Option[String] {
  try {
    cb(connId, path, query, remoteAddress, headers);
    None
  } catch Exception as e {
    Some(value = e.message)
  }
}

func guardOnMessage(cb: in (String, String, String) -> Unit, connId: in String, msgType: in String, data: in String): Option[String] {
  try {
    cb(connId, msgType, data);
    None
  } catch Exception as e {
    Some(value = e.message)
  }
}

func guardOnClose(cb: in (String, Int, String) -> Unit, connId: in String, code: in Int, reason: in String): Option[String] {
  try {
    cb(connId, code, reason);
    None
  } catch Exception as e {
    Some(value = e.message)
  }
}

func guardOnError(cb: in (String, String) -> Unit, connId: in String, message: in String): Option[String] {
  try {
    cb(connId, message);
    None
  } catch Exception as e {
    Some(value = e.message)
  }
}

// ─── Accept-loop policy ──────────────────────────────────────────────────────
/// Whether the accept loop carries on after `e`: a failed accept or bind ends it
/// (the listener is gone), anything else is one bad peer and is skipped.
func acceptShouldContinue(e: in TcpError): Bool {
  match e {
    case AcceptFailed(_) -> false
    case BindFailed(_) -> false
    case _ -> true
  }
}
