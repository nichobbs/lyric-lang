//! tests/lambda_aspect_weaving_tests.l — runtime weaving tests for
//! Lambda.Aspects.DeadlineGuard: the woven handler must short-circuit with
//! TimeoutError near the deadline, proceed otherwise, and treat a negative
//! thresholdMs as a configuration bug raised before the handler runs.
@test_module
package Lambda.AspectWeavingTests

import Std.Core
import Std.Testing
import Lambda
import Lambda.Aspects

aspect GuardDeadline from Lambda.Aspects.DeadlineGuard {
  matches: name like "guarded*"
  config {
    thresholdMs: Long = 1000
  }
}

aspect BadGuard from Lambda.Aspects.DeadlineGuard {
  matches: name like "misconfigured*"
  config {
    thresholdMs: Long = -1
  }
}

func contextWithRemaining(remainingMs: in Long): LambdaContext {
  LambdaContext(
    functionName = "fn",
    functionVersion = "1",
    invokedFunctionArn = "arn:aws:lambda:us-east-1:123:function:fn",
    memoryLimitInMb = 128,
    requestId = "req-1",
    logGroupName = "group",
    logStreamName = "stream",
    remainingTimeMs = remainingMs
  )
}

pub func guardedHandler(ctx: in Lambda.LambdaContext): Result[String, LambdaError] {
  return Ok(value = "ran")
}

pub func misconfiguredHandler(ctx: in Lambda.LambdaContext): Result[String, LambdaError] {
  return Ok(value = "ran")
}

test "DeadlineGuard: enough time left proceeds to the handler" {
  match guardedHandler(contextWithRemaining(5000i64)) {
    case Ok(v) -> assertEqual(v, "ran", "handler must run")
    case Err(e) -> assertTrue(false, "unexpected error: " + errorMessage(e))
  }
}

test "DeadlineGuard: at the threshold short-circuits with TimeoutError" {
  match guardedHandler(contextWithRemaining(1000i64)) {
    case Err(TimeoutError(ms)) -> assertTrue(ms == 1000i64, "reports the remaining time")
    case _ -> assertTrue(false, "must short-circuit with TimeoutError")
  }
}

test "DeadlineGuard: a negative thresholdMs is a configuration bug" {
  var raised = false
  try {
    val _ = misconfiguredHandler(contextWithRemaining(5000i64))
  } catch Bug as e {
    raised = e.message.contains("thresholdMs")
  }
  assertTrue(raised, "negative thresholdMs must panic before the handler")
}
