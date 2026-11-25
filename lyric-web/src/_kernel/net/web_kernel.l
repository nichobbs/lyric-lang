//! Web.Kernel.Runtime (dotnet, the JVM and native) — the per-target kernel of
//! lyric-web.
//!
//! lyric-web serves HTTP through `Std.HttpServer` on every target (docs/73 S6,
//! D791): `Web.serve` runs its own accept loop and calls into this package
//! only for what is genuinely per-target:
//!
//!   * the rate limiter (`checkRateLimit`), `Resilience.takeToken`'s
//!     refilling token bucket, the same one `Ws.Kernel.Net.checkRateLimit`
//!     uses, with separate process-global state keyed by the endpoint string;
//!   * `startWorkerLoop` (issue #5359's background-worker dispatch, #778's
//!     fire-and-forget task boundary) and `spawnRequestJob` (one background
//!     task per request, #7997), both over `Ws.Kernel.Net.runBackground`: a
//!     thread-pool task on dotnet, a virtual thread on the JVM, a thread on
//!     native;
//!   * crash isolation (`runAcceptStep`, and the guarded job/tick runners in
//!     `web_prims.l`): `try`/`catch` on dotnet and the JVM (`_kernel/net/
//!     web_prims.l`), none on native, which has no unwinding (D-N-003;
//!     `_kernel/native/web_prims.l`);
//!   * `upgradeWebSocket`, the `Web.addWebSocket` hand-over through
//!     `Std.HttpServer.takeConnection`;
//!   * on native, `realPath` for the static-file root check.
//!
//! The package has two alternative sources for the prims: exactly one of
//! `_kernel/net/web_prims.l` (dotnet and JVM) and `_kernel/native/web_prims.l`
//! is compiled per build, selected by feature.  This file is compiled for all
//! three targets.
//!
//! See docs/14-native-stdlib-plan.md for the kernel boundary contract.
@io
package Web.Kernel.Runtime

import Std.Console
import Std.Core
import Std.Collections
import Resilience
import Std.Time
import Std.HttpServer
import Web
import Ws
import Ws.Kernel.Net as WsNet

// ─── Rate limiting (token bucket) ────────────────────────────────────────────
//
// One `Resilience.TokenBucket` per key: up to `requestsPerMinute + burstSize`
// calls at once, refilling at `requestsPerMinute` a minute.  It replaced a
// tumbling window whose burst budget never refilled (#7249).
ref record WebRateEntry {
  var scaledTokens: Long = 0i64
  var lastRefillMs: Long = 0i64
}

val webRateLock: WsNet.WsLock = WsNet.newWsLock()

val webRateLimitMap: Map[String, WebRateEntry] = newMap()

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
  WsNet.lockEnter(webRateLock)
  defer {
    WsNet.lockExit(webRateLock)
  }

  val re = match mapGet(webRateLimitMap, endpoint) {
    case Some(existing) -> existing
    case None -> {
      val fullBucket = Resilience.newTokenBucket(requestsPerMinute, burstSize, nowMs)
      val created = WebRateEntry(scaledTokens = fullBucket.scaledTokens, lastRefillMs = fullBucket.lastRefillMs)
      webRateLimitMap.add(endpoint, created)
      created
    }
  }

  val take = Resilience.takeToken(
    Resilience.TokenBucket(scaledTokens = re.scaledTokens, lastRefillMs = re.lastRefillMs),
    requestsPerMinute,
    burstSize,
    nowMs
  )
  re.scaledTokens = take.bucket.scaledTokens
  re.lastRefillMs = take.bucket.lastRefillMs
  take.allowed
}

// ─── Background worker dispatch (#5359) ────────────────────────────────────
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
  WsNet.runBackground({ -> while true { sleepMillis(intervalMs); tickGuarded(worker) } })
}

// ─── Per-request dispatch (#7997) ────────────────────────────────────────────
/// Run `job.run()` on its own thread-pool task so the accept loop can pull the
/// next request immediately. Fire-and-forget: `RequestJob` implementations
/// isolate their own failures (a `Bug` is logged and answered with a 500), so
/// the discarded `Task` is never left holding an unobserved exception. The job
/// is invoked through its interface method, not a captured closure value (see
/// `startWorkerLoop`).
pub func spawnRequestJob(job: in Web.RequestJob): Unit {
  WsNet.runBackground({ -> runJobGuarded(job) })
}

// ─── WebSocket upgrade (`Web.addWebSocket`, #7831) ───────────────────────────
/// Hand the upgrade request `ctx` to `endpoint`: the connection leaves the
/// HTTP server (`Std.HttpServer.takeConnection`) and the endpoint answers
/// `101` (or its `400`/`403` rejection) and serves it on a background task.
/// A request the HTTP server cannot hand over (HTTP/2, HTTP/1.0, or bytes
/// pipelined after it) is answered `400` here.
internal func upgradeWebSocket(endpoint: in Ws.WsEndpoint, ctx: in HttpContext): Unit {
  val headers = requestHeaders(ctx)
  val target = ctx.target
  match takeConnection(ctx) {
    case Ok(conn) -> WsNet.adoptConnection(
      endpoint.registry.registryHandle,
      conn,
      target,
      headers,
      endpoint.path,
      endpoint.allowedOrigins,
      endpoint.sameHostPorts
    )
    case Err(reason) -> respondText(ctx, 400, "WebSocket upgrade refused: " + reason)
  }
}
