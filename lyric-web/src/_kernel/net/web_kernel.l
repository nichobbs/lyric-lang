//! Web.Kernel.Runtime (dotnet) — pure-Lyric rate limiter for lyric-web.
//!
//! Replaces the former @externTarget("Lyric.Ws.RateLimitHost.checkRateLimit")
//! which pointed at a non-existent F# type.  The implementation uses the same
//! tumbling-window algorithm as Ws.Kernel.Net.checkRateLimit but maintains
//! separate process-global state, keyed by the supplied endpoint string.
//!
//! The rate limiter and `startWorkerLoop` (issue #5359's background-worker
//! dispatch, #778's fire-and-forget task boundary) live here: Web.serve's
//! dotnet branch runs its own Std.HttpServer accept loop directly and
//! never calls into this package for anything else. The JVM twin
//! (`_kernel/jvm/web_kernel.l`, same package name — exactly one file is
//! compiled per build, selected by feature) additionally exposes a full
//! Undertow-backed serve(), because Std.HttpServer's JVM kernel doesn't
//! yet expose the primitives Web.dispatch needs; it does not yet expose a
//! `startWorkerLoop` twin (tracked separately, blocked on the pre-existing
//! JVM compile failures #5444/#5458 that already keep `lyric-web`'s test
//! suite from building on that target).
//!
//! All functions are @cfg(feature = "dotnet") so they are erased when
//! the dotnet feature is not active (e.g. during JVM builds).
//!
//! See docs/14-native-stdlib-plan.md for the kernel boundary contract.
@cfg(feature = "dotnet")
package Web.Kernel.Runtime

import Std.Console
import Std.Core
import Std.Time
import Web

extern type ConcurrentDict[K, V] = "System.Collections.Concurrent.ConcurrentDictionary`2"

@externTarget("System.Collections.Concurrent.ConcurrentDictionary`2..ctor")
func newConcurrentDict[K, V](): ConcurrentDict[K, V] = ()

@externTarget("System.Collections.Concurrent.ConcurrentDictionary`2.TryGetValue")
func cdTryGetValue[K, V](dict: in ConcurrentDict[K, V], key: in K, value: out V): Bool = ()

@externTarget("System.Collections.Concurrent.ConcurrentDictionary`2.TryAdd")
func cdTryAdd[K, V](dict: in ConcurrentDict[K, V], key: in K, value: in V): Bool = ()

@axiom("System.Threading.Monitor.Enter — acquires an exclusive lock on obj")
@externTarget("System.Threading.Monitor.Enter")
func monitorEnter[T](obj: in T): Unit = ()

@axiom("System.Threading.Monitor.Exit — releases an exclusive lock on obj")
@externTarget("System.Threading.Monitor.Exit")
func monitorExit[T](obj: in T): Unit = ()

// ─── Rate limiting (tumbling window) ─────────────────────────────────────────
//
// Uses a tumbling (fixed-reset) 60-second window per endpoint key.  The burst
// budget is one-shot: it does not refill when the window resets.  A sliding
// window with boundary-burst protection is tracked under #778.
record WebRateEntry {
  var windowStartMs: Long = 0i64
  var usedInWindow: Int = 0
  var burstAvailable: Int = 0
}

record WebRateLock {
}

val webRateLock: WebRateLock = WebRateLock()

val webRateLimitMap: ConcurrentDict[String, WebRateEntry] = newConcurrentDict()

/// Check whether a call from this endpoint is within the rate limit.
/// Returns true (allow) or false (deny).  State is per-process and
/// per-endpoint; resets on process restart.
@stable(since = "0.1")
pub func checkRateLimit(endpoint: in String, requestsPerMinute: in Int, burstSize: in Int): Bool
  requires: endpoint.length > 0
  requires: requestsPerMinute > 0
  requires: burstSize > 0
{
  val nowMs = nowEpochMillis()
  monitorEnter(webRateLock)
  defer {
    monitorExit(webRateLock)
  }

  var re: WebRateEntry = default()
  if not cdTryGetValue(webRateLimitMap, endpoint, re) {
    val newEntry = WebRateEntry(windowStartMs = nowMs, usedInWindow = 0, burstAvailable = burstSize)
    val _ = cdTryAdd(webRateLimitMap, endpoint, newEntry)
    var re2: WebRateEntry = default()
    if cdTryGetValue(webRateLimitMap, endpoint, re2) {
      re = re2
    } else {
      re = newEntry
    }
  }

  val elapsed: Long = nowMs - re.windowStartMs
  if elapsed >= 60000i64 {
    re.windowStartMs = nowMs
    re.usedInWindow = 0
  }

  if re.usedInWindow < requestsPerMinute {
    re.usedInWindow = re.usedInWindow + 1
    return true
  }

  if re.burstAvailable > 0 {
    re.burstAvailable = re.burstAvailable - 1
    re.usedInWindow = re.usedInWindow + 1
    return true
  }

  false
}

// ─── Background worker dispatch (#5359) ────────────────────────────────────
extern type BclTask = "System.Threading.Tasks.Task"

/// `Task.Run(Action)` genuinely runs `action` on a thread-pool thread,
/// concurrently with the caller — verified directly against this exact
/// `() -> Unit` shape (a zero-arg, `Unit`-returning closure targets the
/// non-generic `System.Action`, matched by a real BCL overload). This is
/// narrower than `Std.Task.scopeSpawn`'s own `Task.Run(Action,
/// CancellationToken)` binding, separately documented in `_kernel/task.l`
/// as not invoking its closure on `--target dotnet` — that finding does not
/// reproduce against the plain one-argument overload this calls.
@externStatic
@externTarget("System.Threading.Tasks.Task.Run")
func taskRunAction(action: in () -> Unit): BclTask = ()

/// Start `worker.tick()` running forever on a background thread-pool task,
/// once every `intervalMs`. Fire-and-forget: the returned `Task` is
/// deliberately discarded — `Web.serve`'s accept loop runs for the life of
/// the process, so there is nothing to join.
///
/// Takes the `Worker` interface value directly rather than a `() ->
/// Unit` closure wrapping `worker.tick()`: invoking a captured
/// closure-typed VALUE from inside another closure panics at codegen
/// (`T0123`, a real self-hosted MSIL gap reproduced in isolation with a
/// single-package repro, independent of #5363's cross-package case) —
/// invoking an interface method from inside a closure does not hit this,
/// so the loop below calls `worker.tick()` directly.
///
/// Each `tick()` is crash-isolated (#6935): since this loop runs
/// fire-and-forget with its `Task` never observed, an uncaught `Bug`
/// would otherwise silently and permanently stop this worker's loop with
/// no logging, while the server keeps running as if nothing happened —
/// exactly the failure mode `serve`/`serveStreaming`'s accept loops are
/// already hardened against (#5261). A failing tick is logged and the
/// loop keeps going on its next interval.
pub func startWorkerLoop(intervalMs: in Int, worker: in Web.Worker): Unit {
  val _ = taskRunAction(
    { ->
      while true {
        sleepMillis(intervalMs)
        try {
          worker.tick()
        } catch Bug as e {
          Console.error("[lyric-web] worker tick failed: " + e.message)
        }
      }
    }
  )
}
