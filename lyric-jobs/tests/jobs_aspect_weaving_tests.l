//! tests/jobs_aspect_weaving_tests.l — runtime weaving tests for
//! Jobs.Aspects.Retryable: retries up to maxAttempts, stops on success, and
//! treats an impossible configuration as a bug raised before the handler
//! runs (#7324).
@test_module
package Jobs.AspectWeavingTests

import Std.Core
import Std.Testing
import Jobs
import Jobs.Aspects

record Counter {
  var count: Int = 0
}

aspect FastRetry from Jobs.Aspects.Retryable {
  matches: name like "retried*"
  config {
    maxAttempts: Int = 3
    initialDelayMs: Int = 1
    maxDelayMs: Int = 5
  }
}

aspect BadRetry from Jobs.Aspects.Retryable {
  matches: name like "misconfigured*"
  config {
    maxAttempts: Int = 3
    initialDelayMs: Int = 60000
    maxDelayMs: Int = 30000
  }
}

val failingCalls: Counter = Counter()

val flakyCalls: Counter = Counter()

val badCalls: Counter = Counter()

pub func retriedAlwaysFails(spec: in String): Result[String, JobError] {
  failingCalls.count = failingCalls.count + 1
  return Err(JobError(message = "boom", code = "E"))
}

pub func retriedFlaky(spec: in String): Result[String, JobError] {
  flakyCalls.count = flakyCalls.count + 1
  if flakyCalls.count < 2 {
    return Err(JobError(message = "transient", code = "T"))
  }
  return Ok("done")
}

pub func misconfiguredHandler(spec: in String): Result[String, JobError] {
  badCalls.count = badCalls.count + 1
  return Ok("ran")
}

test "Retryable: a failing handler runs maxAttempts times and returns the last Err" {
  failingCalls.count = 0
  match retriedAlwaysFails("job") {
    case Ok(_) -> assertTrue(false, "must fail")
    case Err(e) -> assertEqual(e.code, "E", "the handler's error is returned")
  }
  assertEqualInt(failingCalls.count, 3, "three attempts")
}

test "Retryable: stops retrying once the handler succeeds" {
  flakyCalls.count = 0
  match retriedFlaky("job") {
    case Ok(v) -> assertEqual(v, "done", "the successful result is returned")
    case Err(_) -> assertTrue(false, "the second attempt succeeds")
  }
  assertEqualInt(flakyCalls.count, 2, "two attempts")
}

test "Retryable: initialDelayMs above maxDelayMs is a configuration bug raised before the handler" {
  badCalls.count = 0
  assertPanicsWith("bad config", "initialDelayMs", { -> val _ = misconfiguredHandler("job") })
  assertEqualInt(badCalls.count, 0, "the handler never ran")
}
