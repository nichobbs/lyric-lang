//! tests/rate_limit_tests.l — regression tests for the Web.Kernel.Net.checkRateLimit
//! implementation (#2151).
//!
//! The `checkRateLimit` function was previously a dead stub returning `false`
//! (always-deny).  After the PR that wired it to the real sliding-window
//! implementation, these tests confirm:
//!   * Calls within the rate limit are allowed.
//!   * Calls beyond the rate limit are denied.
//!   * The burst budget is consumed before denials start.
//!   * A unique endpoint key is independent from other endpoints.
@test_module
package Web.RateLimitTests

import Std.Core
import Std.Testing
import Std.Time as Time
import Web.Kernel.Net as HttpKernel

// ─── checkRateLimit unit tests ───────────────────────────────────────────────
//
// Each test appends a per-invocation epoch-millis suffix to its endpoint key
// so that re-runs of the test suite in the same process do not share counters
// via the process-global rate-limit map.  `requestsPerMinute = 2` and
// `burstSize = 1` gives the smallest meaningful window for fast, deterministic
// assertions.
test "checkRateLimit: first call within limit is allowed" {
  // First call on a fresh key must always be allowed (count 1 <= RPM 10).
  val ep = "Web.RateLimitTests/firstCallAllowed/" + toString(Time.nowEpochMillis())
  val allowed = HttpKernel.checkRateLimit(ep, 10, 5)
  assertTrue(allowed, "first call to a fresh endpoint must be allowed")
}

test "checkRateLimit: calls within requestsPerMinute are allowed" {
  val ep = "Web.RateLimitTests/withinLimit/" + toString(Time.nowEpochMillis())
  // Allow up to 3 calls per minute, no burst.  All three must succeed.
  val a1 = HttpKernel.checkRateLimit(ep, 3, 1)
  val a2 = HttpKernel.checkRateLimit(ep, 3, 1)
  val a3 = HttpKernel.checkRateLimit(ep, 3, 1)
  assertTrue(a1, "call 1 of 3 must be allowed")
  assertTrue(a2, "call 2 of 3 must be allowed")
  assertTrue(a3, "call 3 of 3 must be allowed")
}

test "checkRateLimit: call beyond requestsPerMinute is denied" {
  val ep = "Web.RateLimitTests/exceedLimit/" + toString(Time.nowEpochMillis())
  // RPM = 2, burst = 0 (minimum is 1 per contract — use 1 then exhaust it).
  // 3 calls within the same window: calls 1+2 consume the RPM budget;
  // call 3 must be denied.  burstSize = 1 so the burst is consumed on the
  // 3rd call leaving the 4th denied.
  val _ = HttpKernel.checkRateLimit(ep, 2, 1)
  val _ = HttpKernel.checkRateLimit(ep, 2, 1)
  val _ = HttpKernel.checkRateLimit(ep, 2, 1)
  val denied = HttpKernel.checkRateLimit(ep, 2, 1)
  assertTrue(not denied, "4th call with RPM=2 and burst=1 must be denied")
}

test "checkRateLimit: burst budget defers denial past requestsPerMinute" {
  val ep = "Web.RateLimitTests/burstDefers/" + toString(Time.nowEpochMillis())
  // RPM = 1, burst = 2.  Call 1 uses the RPM slot; calls 2+3 use burst.
  // Call 4 must be denied.
  val a1 = HttpKernel.checkRateLimit(ep, 1, 2)
  val a2 = HttpKernel.checkRateLimit(ep, 1, 2)
  val a3 = HttpKernel.checkRateLimit(ep, 1, 2)
  val denied = HttpKernel.checkRateLimit(ep, 1, 2)
  assertTrue(a1, "call 1 within RPM must be allowed")
  assertTrue(a2, "call 2 using burst budget must be allowed")
  assertTrue(a3, "call 3 using burst budget must be allowed")
  assertTrue(not denied, "call 4 after RPM + burst exhausted must be denied")
}

test "checkRateLimit: distinct endpoints have independent counters" {
  val ts = toString(Time.nowEpochMillis())
  val ep1 = "Web.RateLimitTests/independent/a/" + ts
  val ep2 = "Web.RateLimitTests/independent/b/" + ts
  // Exhaust ep1 (RPM = 1, burst = 1 → 2 allowed, 3rd denied).
  val _ = HttpKernel.checkRateLimit(ep1, 1, 1)
  val _ = HttpKernel.checkRateLimit(ep1, 1, 1)
  val _ = HttpKernel.checkRateLimit(ep1, 1, 1)
  // ep2 must be independent — its first call is a fresh counter.
  val ep2Allowed = HttpKernel.checkRateLimit(ep2, 1, 1)
  assertTrue(ep2Allowed, "ep2's first call must be allowed regardless of ep1's state")
}
