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
