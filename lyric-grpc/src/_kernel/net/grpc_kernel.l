//! Grpc.Kernel.Net — .NET extern boundary for gRPC client and server.
//!
//! Client side (Grpc.Net.Client):
//!   netOpenChannel / netCloseChannel — channel lifecycle
//!   netCallUnary                     — blocking unary RPC
//!   netOpenServerStream / netNextStreamMessage / netCloseStream — server streaming
//!
//! Server side (Grpc.AspNetCore):
//!   serve()          — start the gRPC server host
//!   checkRateLimit() — in-process sliding-window rate limiter
//!
//! Pass-through marshaller: the client uses a Grpc.Core.Marshaller<byte[]>
//! whose serialiser and deserialiser are identity functions, so Lyric callers
//! supply and receive raw protobuf bytes without generated stub code.
//!
//! For each incoming server RPC the kernel:
//!   1. Matches the request against the GrpcRoute table.
//!   2. Deserializes the protobuf request message to the handler's first param.
//!   3. Extracts "authorization" metadata and passes it as `authToken: String`.
//!   4. Resolves the handler by qualified name and invokes it.
//!   5. Maps Result[T, GrpcStatus] → gRPC response:
//!        Ok(value)   → Status.OK + serialized response
//!        Err(status) → status.code + status.message in trailing metadata
//!
//! JWT verification lives in Auth.Kernel.Net (lyric-auth).
//!
//! Only active when compiled with feature = "dotnet".
//! See docs/14-native-stdlib-plan.md for the kernel boundary contract.
@cfg(feature = "dotnet")
package Grpc.Kernel.Net

import Grpc.Types

// ─── Opaque .NET types ────────────────────────────────────────────────────────
extern type NetGrpcChannel = "Grpc.Net.Client.GrpcChannel"

extern type NetGrpcStream = "System.Collections.Generic.IAsyncEnumerator`1[System.Byte[]]"

// ─── Client: channel lifecycle ────────────────────────────────────────────────
@axiom("Grpc.Net.Client.GrpcChannel conforms to its NuGet contract")
extern package Grpc.Net.Client.Api {
  pub func netOpenChannel(address: in String): Result[GrpcChannel, String]
  pub func netCloseChannel(channel: GrpcChannel): Unit
  // ─── Client: unary calls ──────────────────────────────────────────────────────
}

@axiom("Grpc.Net.Client CallInvoker with pass-through marshaller conforms to its NuGet contract")
extern package Grpc.Net.Client.Unary {
  pub func netCallUnary(channel: GrpcChannel, service: in String, method: in String, payload: in slice[Byte], timeoutMs: in Int, metadata: in String): Result[slice[Byte], GrpcStatus]
  // ─── Client: server-streaming calls ──────────────────────────────────────────
}

@axiom("Grpc.Net.Client server-streaming CallInvoker conforms to its NuGet contract")
extern package Grpc.Net.Client.Stream {
  pub func netOpenServerStream(channel: GrpcChannel, service: in String, method: in String, payload: in slice[Byte], timeoutMs: in Int, metadata: in String): Result[GrpcStream, GrpcStatus]

  pub func netNextStreamMessage(stream: GrpcStream): Result[Option[slice[Byte]], GrpcStatus]
  pub func netCloseStream(stream: GrpcStream): Unit
  // ─── Server: hosting ─────────────────────────────────────────────────────────
}

@axiom("Grpc.AspNetCore / grpc-dotnet server host")
extern package Grpc.AspNetCore {
  pub func serve(host: String, port: Int, reflectionEnabled: Bool, maxConnectionIdleMs: Int, registry: Grpc.ServiceRegistry): Unit
}

@axiom("Grpc.AspNetCore IHost.StopAsync provides drain-with-timeout shutdown")
extern package Grpc.AspNetCore.Managed {
  pub func netStartHandle(host: String, port: Int, reflectionEnabled: Bool, maxConnectionIdleMs: Int, registry: Grpc.ServiceRegistry): GrpcServerHandle

  pub func netStopHandle(handle: GrpcServerHandle, drainTimeoutMs: Int): Unit
    requires: drainTimeoutMs >= 0
  // ─── Server: rate limiting ────────────────────────────────────────────────────
}

// ─── Server: rate limiting (System.Threading.RateLimiting) ────────────────────
// Two independent `SlidingWindowRateLimiter`s per method, composed with AND: a
// window-only limiter cannot express both "average request rate" and
// "instantaneous burst ceiling" as separate numbers, so a request must clear a
// coarse 60s/requestsPerMinute-permit limiter AND a fine 1s/burstSize-permit
// limiter. The burst limiter is checked first so a request that fails it never
// spends a (scarcer) sustained-window permit.
extern type NetRateLimiterOptions = "System.Threading.RateLimiting.SlidingWindowRateLimiterOptions"

extern type NetRateLimiter = "System.Threading.RateLimiting.SlidingWindowRateLimiter"

extern type NetRateLimitLease = "System.Threading.RateLimiting.RateLimitLease"

extern type NetQueueProcessingOrder = "System.Threading.RateLimiting.QueueProcessingOrder"

extern type NetTimeSpan = "System.TimeSpan"

// `Std.HttpServerHost` (`lyric-stdlib/std/_kernel/http_server.l`) declares
// the identical binding, but as a non-`pub` module-private helper — not
// importable from here. Re-declared locally rather than exported upstream,
// per the kernel-boundary rule that only a file's own `_kernel/` package may
// declare `extern`/`@externTarget` surface (docs/14-native-stdlib-plan.md).
extern type Semaphore = "System.Threading.SemaphoreSlim"

@externTarget("System.Threading.SemaphoreSlim..ctor")
func newSemaphore(initialCount: in Int): Semaphore = ()

@externInstance
@externTarget("System.Threading.SemaphoreSlim.Wait")
func semWait(s: in Semaphore): Unit = ()

@externInstance
@externTarget("System.Threading.SemaphoreSlim.Release")
func semRelease(s: in Semaphore): Int = ()

@axiom("System.Threading.RateLimiting.SlidingWindowRateLimiter conforms to its documented .NET contract")
@externTarget("System.Threading.RateLimiting.SlidingWindowRateLimiterOptions..ctor")
func newRateLimiterOptions(): NetRateLimiterOptions = ()

@externInstance
@externTarget("System.Threading.RateLimiting.SlidingWindowRateLimiterOptions.set_Window")
func rlOptSetWindow(o: in NetRateLimiterOptions, w: in NetTimeSpan): Unit = ()

@externInstance
@externTarget("System.Threading.RateLimiting.SlidingWindowRateLimiterOptions.set_PermitLimit")
func rlOptSetPermitLimit(o: in NetRateLimiterOptions, n: in Int): Unit = ()

@externInstance
@externTarget("System.Threading.RateLimiting.SlidingWindowRateLimiterOptions.set_SegmentsPerWindow")
func rlOptSetSegmentsPerWindow(o: in NetRateLimiterOptions, n: in Int): Unit = ()

@externInstance
@externTarget("System.Threading.RateLimiting.SlidingWindowRateLimiterOptions.set_QueueLimit")
func rlOptSetQueueLimit(o: in NetRateLimiterOptions, n: in Int): Unit = ()

@externInstance
@externTarget("System.Threading.RateLimiting.SlidingWindowRateLimiterOptions.set_QueueProcessingOrder")
func rlOptSetQueueOrder(o: in NetRateLimiterOptions, order: in NetQueueProcessingOrder): Unit = ()

@externInstance
@externTarget("System.Threading.RateLimiting.SlidingWindowRateLimiterOptions.set_AutoReplenishment")
func rlOptSetAutoReplenishment(o: in NetRateLimiterOptions, v: in Bool): Unit = ()

@externTarget("System.Threading.RateLimiting.QueueProcessingOrder.OldestFirst")
func queueOrderOldestFirst(): NetQueueProcessingOrder = ()

@externTarget("System.TimeSpan.FromMilliseconds")
func rlTimeSpanFromMillis(ms: in Double): NetTimeSpan = ()

@externTarget("System.Threading.RateLimiting.SlidingWindowRateLimiter..ctor")
func newRateLimiter(o: in NetRateLimiterOptions): NetRateLimiter = ()

@externInstance
@externTarget("System.Threading.RateLimiting.RateLimiter.AttemptAcquire")
func rlAttemptAcquire(l: in NetRateLimiter, permitCount: in Int): NetRateLimitLease = ()

@externInstance
@externTarget("System.Threading.RateLimiting.RateLimitLease.get_IsAcquired")
func rlLeaseIsAcquired(lease: in NetRateLimitLease): Bool = ()

@externInstance
@externTarget("System.Threading.RateLimiting.RateLimitLease.Dispose")
func rlLeaseDispose(lease: in NetRateLimitLease): Unit = ()

func newSlidingWindowLimiter(windowMs: in Int, permitLimit: in Int, segmentsPerWindow: in Int): NetRateLimiter {
  val o = newRateLimiterOptions()
  rlOptSetWindow(o, rlTimeSpanFromMillis(windowMs.toDouble()))
  rlOptSetPermitLimit(o, permitLimit)
  rlOptSetSegmentsPerWindow(o, segmentsPerWindow)
  rlOptSetQueueLimit(o, 0)
  rlOptSetQueueOrder(o, queueOrderOldestFirst())
  rlOptSetAutoReplenishment(o, true)
  newRateLimiter(o)
}

// Per-method (sustained, burst) limiter pair, created lazily on first use and
// reused across calls. Guarded by `rateLimiterLock` since the registry `Map`
// itself is an ordinary mutable Lyric collection with no built-in thread
// safety, and concurrent RPCs may race to create the same method's entry.
record RateLimiterPair {
  sustained: NetRateLimiter
  burst: NetRateLimiter
}

val rateLimiters: Map[String, RateLimiterPair] = newMap()

val rateLimiterLock: Semaphore = newSemaphore(1)

func getOrCreateLimiterPair(method: in String, requestsPerMinute: in Int, burstSize: in Int): RateLimiterPair {
  semWait(rateLimiterLock)
  defer {
    val _ = semRelease(rateLimiterLock);
    ()
  }
  match mapGet(rateLimiters, method) {
    case Some(pair) -> pair
    case None -> {
      val pair = RateLimiterPair(
        sustained = newSlidingWindowLimiter(60000, requestsPerMinute, 6),
        burst = newSlidingWindowLimiter(1000, burstSize, 1)
      )
      rateLimiters.add(method, pair)
      pair
    }
  }
}

/// Check (and consume, if allowed) one permit from both the sustained
/// (`requestsPerMinute` over a rolling 60s window) and burst (`burstSize`
/// over a rolling 1s window) limiters for `method`. Returns `true` only if
/// both grant a permit.
pub func checkRateLimit(method: in String, requestsPerMinute: in Int, burstSize: in Int): Bool
  requires: requestsPerMinute > 0
  requires: burstSize > 0
{
  val pair = getOrCreateLimiterPair(method, requestsPerMinute, burstSize)
  val burstLease = rlAttemptAcquire(pair.burst, 1)
  val burstOk = rlLeaseIsAcquired(burstLease)
  rlLeaseDispose(burstLease)
  if not burstOk {
    return false
  }
  val sustainedLease = rlAttemptAcquire(pair.sustained, 1)
  val sustainedOk = rlLeaseIsAcquired(sustainedLease)
  rlLeaseDispose(sustainedLease)
  sustainedOk
}
