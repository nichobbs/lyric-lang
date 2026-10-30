//! tests/rate_limit_jvm_tests.l — Grpc.checkRateLimit on `--target jvm`, the
//! `Lyric.Resilience` token bucket in `Grpc.Kernel.Jvm` (#5409).
//!
//! The dotnet kernel uses two `SlidingWindowRateLimiter`s (see
//! `rate_limit_tests.l`); the JVM kernel's bucket holds `requestsPerMinute +
//! burstSize` permits and refills at `requestsPerMinute` a minute. Each test
//! uses its own method name (the bucket registry is process-wide) and
//! `requestsPerMinute = 1` so a permit is refilled only every 60 s.
@cfg(target = "jvm")
@test_module
package Grpc.RateLimitJvmTests

import Std.Core
import Std.Testing
import Grpc

test "checkRateLimit: rpm + burst permits are allowed at once, the next call is denied" {
  val method = "svc/JvmBurst"
  assertTrue(Grpc.checkRateLimit(method, 1, 2), "1st of 3 permits")
  assertTrue(Grpc.checkRateLimit(method, 1, 2), "2nd of 3 permits")
  assertTrue(Grpc.checkRateLimit(method, 1, 2), "3rd of 3 permits")
  assertFalse(Grpc.checkRateLimit(method, 1, 2), "4th call exceeds rpm + burst and nothing has refilled")
}

test "checkRateLimit: different method names have independent buckets" {
  assertTrue(Grpc.checkRateLimit("svc/JvmA", 1, 1), "first method's 1st of 2 permits")
  assertTrue(Grpc.checkRateLimit("svc/JvmA", 1, 1), "first method's 2nd of 2 permits")
  assertFalse(Grpc.checkRateLimit("svc/JvmA", 1, 1), "first method is exhausted")
  assertTrue(Grpc.checkRateLimit("svc/JvmB", 1, 1), "second method is unaffected")
}

test "checkRateLimit: a different (rpm, burst) for the same method gets its own bucket (#7247)" {
  val method = "svc/JvmReconfigured"
  assertTrue(Grpc.checkRateLimit(method, 1, 1), "1st configuration's 1st of 2 permits")
  assertTrue(Grpc.checkRateLimit(method, 1, 1), "1st configuration's 2nd of 2 permits")
  assertFalse(Grpc.checkRateLimit(method, 1, 1), "1st configuration is exhausted")
  assertTrue(Grpc.checkRateLimit(method, 2, 1), "a changed rpm starts a fresh bucket")
}

test "checkRateLimit: requestsPerMinute=0 violates its contract" {
  var raised = false
  try {
    val _ = Grpc.checkRateLimit("svc/JvmBadRpm", 0, 1)
  } catch Bug as _ {
    raised = true
  }
  assertTrue(raised, "a zero rate is a contract violation")
}

test "checkRateLimit: burstSize=0 violates its contract" {
  var raised = false
  try {
    val _ = Grpc.checkRateLimit("svc/JvmBadBurst", 1, 0)
  } catch Bug as _ {
    raised = true
  }
  assertTrue(raised, "a zero burst is a contract violation")
}
