//! tests/domain_tests.l — unit tests for JobQueue.Domain.
//!
//! Covers the @proof_required state-machine invariants, status
//! label/parse round-trips, and the LedgerError message formatter.
//! All tests are pure; no I/O.
//!
//! Run:  lyric test examples/jobqueue/tests/domain_tests.l
@test_module
package JobQueue.DomainTests

import Std.Core
import Std.Testing
import JobQueue.Domain

// ─── jobStatusLabel / jobStatusFromString ─────────────────────────────────────
test "jobStatusFromString parses pending" {
  match JobQueue.Domain.jobStatusFromString("pending") {
    case None -> assertTrue(false, "should parse 'pending'")
    case Some(s) -> assertEqual(JobQueue.Domain.jobStatusLabel(s), "pending", "round-trip")
  }
}

test "jobStatusFromString parses running" {
  match JobQueue.Domain.jobStatusFromString("running") {
    case None -> assertTrue(false, "should parse 'running'")
    case Some(s) -> assertEqual(JobQueue.Domain.jobStatusLabel(s), "running", "round-trip")
  }
}

test "jobStatusFromString parses completed" {
  match JobQueue.Domain.jobStatusFromString("completed") {
    case None -> assertTrue(false, "should parse 'completed'")
    case Some(s) -> assertEqual(JobQueue.Domain.jobStatusLabel(s), "completed", "round-trip")
  }
}

test "jobStatusFromString parses failed" {
  match JobQueue.Domain.jobStatusFromString("failed") {
    case None -> assertTrue(false, "should parse 'failed'")
    case Some(s) -> assertEqual(JobQueue.Domain.jobStatusLabel(s), "failed", "round-trip")
  }
}

test "jobStatusFromString returns None for unknown status" {
  assertTrue(isNone(JobQueue.Domain.jobStatusFromString("unknown")), "unknown → None")
}

test "jobStatusFromString returns None for empty string" {
  assertTrue(isNone(JobQueue.Domain.jobStatusFromString("")), "empty → None")
}

// ─── statusTransition ────────────────────────────────────────────────────────
//
// statusTransition is a proof oracle: its @proof_required requires: clauses
// define exactly which transitions are legal.  Any call with an illegal
// (from, to) pair violates the requires contract rather than returning false;
// negative tests are therefore not applicable here.
test "statusTransition allows Pending to Running" {
  val ok = JobQueue.Domain.statusTransition(JobStatus.Pending, JobStatus.Running)
  assertTrue(ok, "Pending → Running is legal")
}

test "statusTransition allows Running to Completed" {
  val ok = JobQueue.Domain.statusTransition(JobStatus.Running, JobStatus.Completed)
  assertTrue(ok, "Running → Completed is legal")
}

test "statusTransition allows Running to Failed" {
  val ok = JobQueue.Domain.statusTransition(JobStatus.Running, JobStatus.Failed)
  assertTrue(ok, "Running → Failed is legal")
}

test "statusTransition allows Failed to Pending for retry" {
  val ok = JobQueue.Domain.statusTransition(JobStatus.Failed, JobStatus.Pending)
  assertTrue(ok, "Failed → Pending is legal (retry)")
}

// ─── retryAllowed ─────────────────────────────────────────────────────────────
//
// retryAllowed is a proof oracle: for all inputs satisfying requires:
// (retryCount < maxRetries, maxRetries <= 10) it returns true.
// Inputs violating requires: trigger a contract assertion.
test "retryAllowed holds for count zero" {
  val ok = JobQueue.Domain.retryAllowed(0, 3)
  assertTrue(ok, "0 < 3 — retry allowed")
}

test "retryAllowed holds one below the limit" {
  val ok = JobQueue.Domain.retryAllowed(2, 3)
  assertTrue(ok, "2 < 3 — retry allowed")
}

test "retryAllowed holds for maximum budget" {
  val ok = JobQueue.Domain.retryAllowed(9, 10)
  assertTrue(ok, "9 < 10 — retry allowed at max budget")
}

test "retryAllowed holds for budget of one" {
  val ok = JobQueue.Domain.retryAllowed(0, 1)
  assertTrue(ok, "0 < 1 — single-retry budget")
}

// ─── errorMessage ─────────────────────────────────────────────────────────────
test "errorMessage JobNotFound contains id" {
  val msg = JobQueue.Domain.errorMessage(JobError.JobNotFound(id = 42))
  assertTrue(msg.indexOf("42") >= 0, "message contains id 42")
}

test "errorMessage InvalidTransition contains both statuses" {
  val msg = JobQueue.Domain.errorMessage(JobError.InvalidTransition(from = "completed", to = "pending"))
  assertTrue(msg.indexOf("completed") >= 0, "message contains from status")
  assertTrue(msg.indexOf("pending") >= 0, "message contains to status")
}

test "errorMessage RetryLimitExceeded contains id and counts" {
  val msg = JobQueue.Domain.errorMessage(JobError.RetryLimitExceeded(id = 7, retryCount = 3, maxRetries = 3))
  assertTrue(msg.indexOf("7") >= 0, "message contains job id")
  assertTrue(msg.indexOf("3") >= 0, "message contains retry count")
}

test "errorMessage DatabaseError contains driver message" {
  val msg = JobQueue.Domain.errorMessage(JobError.DatabaseError(message = "connection refused"))
  assertTrue(msg.indexOf("connection refused") >= 0, "driver message present")
}
