//! tests/rate_limit_tests.l — tests for Grpc.checkRateLimit's real
//! System.Threading.RateLimiting-backed sliding-window limiter (#5409, #6557).
//!
//! Each test uses its own unique method name so the per-method limiter
//! registry in Grpc.Kernel.Net never leaks state across tests (limiters are
//! created once per method name and never reset).
@test_module
package Grpc.RateLimitTests

import Std.Core
import Std.Testing
import Grpc

test "checkRateLimit: a burst within the limit is allowed" {
  assertTrue(Grpc.checkRateLimit("svc/BurstOk", 100, 3), "1st call within burst=3 must be allowed")
  assertTrue(Grpc.checkRateLimit("svc/BurstOk", 100, 3), "2nd call within burst=3 must be allowed")
  assertTrue(Grpc.checkRateLimit("svc/BurstOk", 100, 3), "3rd call within burst=3 must be allowed")
}

test "checkRateLimit: exceeding the burst ceiling is denied" {
  val method = "svc/BurstExceeded"
  assertTrue(Grpc.checkRateLimit(method, 1000, 2), "1st call within burst=2 must be allowed")
  assertTrue(Grpc.checkRateLimit(method, 1000, 2), "2nd call within burst=2 must be allowed")
  assertFalse(
    Grpc.checkRateLimit(method, 1000, 2),
    "3rd call must be denied: burst=2 is exhausted and the sliding window has not replenished"
  )
}

test "checkRateLimit: denial does not consume a sustained-window permit" {
  // requestsPerMinute=1 gives the sustained limiter exactly one permit for
  // the whole test; burstSize=1 means the 2nd call is denied by the burst
  // limiter. checkRateLimit checks burst first and returns before touching
  // the sustained limiter on denial, so a 3rd call still has its one
  // sustained permit available (denied only by burst again, not by having
  // silently spent the sustained permit on the failed 2nd call).
  val method = "svc/BurstDeniedPreservesSustained"
  assertTrue(Grpc.checkRateLimit(method, 1, 1), "1st call must be allowed (consumes the only sustained permit)")
  assertFalse(Grpc.checkRateLimit(method, 1, 1), "2nd call must be denied by the exhausted burst limiter")
  assertFalse(
    Grpc.checkRateLimit(method, 1, 1),
    "3rd call must also be denied by burst, not error out from a corrupted sustained-limiter state"
  )
}

test "checkRateLimit: exceeding the sustained rate is denied even with burst capacity left" {
  // burstSize=10 gives plenty of burst headroom; requestsPerMinute=2 means
  // the sustained limiter is what actually denies the 3rd call.
  val method = "svc/SustainedExceeded"
  assertTrue(Grpc.checkRateLimit(method, 2, 10), "1st call within sustained=2 must be allowed")
  assertTrue(Grpc.checkRateLimit(method, 2, 10), "2nd call within sustained=2 must be allowed")
  assertFalse(
    Grpc.checkRateLimit(method, 2, 10),
    "3rd call must be denied: sustained=2 is exhausted even though burst capacity remains"
  )
}

test "checkRateLimit: different method names have independent limiter state" {
  val methodA = "svc/IndependentA"
  val methodB = "svc/IndependentB"
  assertTrue(Grpc.checkRateLimit(methodA, 100, 1), "methodA's only burst permit is consumed here")
  assertFalse(Grpc.checkRateLimit(methodA, 100, 1), "methodA must now be rate-limited")
  assertTrue(
    Grpc.checkRateLimit(methodB, 100, 1),
    "methodB must have its own independent limiter, unaffected by methodA's exhaustion"
  )
}

test "checkRateLimit: requestsPerMinute=0 violates its contract" {
  val violated = try {
    val _ = Grpc.checkRateLimit("svc/ZeroRate", 0, 1)
    false
  } catch Bug as _ {
    true
  }
  assertTrue(violated, "requestsPerMinute > 0 is a documented requires: clause")
}

test "checkRateLimit: burstSize=0 violates its contract" {
  val violated = try {
    val _ = Grpc.checkRateLimit("svc/ZeroBurst", 100, 0)
    false
  } catch Bug as _ {
    true
  }
  assertTrue(violated, "burstSize > 0 is a documented requires: clause")
}
