//! tests/jobqueue_tests.l — unit tests for JSON serialization.
//!
//! Tests JobQueue.Jobs.toJson without touching the database.
//! Each test constructs a domain record in-process and checks the JSON string.
//!
//! Substring checks assume compact JSON (no space after ":").
//!
//! Run:  lyric test examples/jobqueue/tests/jobqueue_tests.l
@test_module
package JobQueue.JobQueueTests

import Std.Core
import Std.Testing
import JobQueue.Domain
import JobQueue.Jobs

// ─── toJson — structural ──────────────────────────────────────────────────────
test "toJson produces valid JSON object" {
  val j = Job(
    id = 1,
    kind = "noop",
    payload = "{}",
    status = JobStatus.Pending,
    retryCount = 0,
    maxRetries = 3,
    workerId = "",
    error = "",
    createdAt = "2024-01-15T00:00:00Z"
  )
  val json = JobQueue.Jobs.toJson(j)
  assertEqual(json.first.toString(), "{", "starts with {")
  assertEqual(json.last.toString(), "}", "ends with }")
}

test "toJson includes id" {
  val j = Job(
    id = 99,
    kind = "noop",
    payload = "{}",
    status = JobStatus.Pending,
    retryCount = 0,
    maxRetries = 3,
    workerId = "",
    error = "",
    createdAt = "2024-01-15T00:00:00Z"
  )
  val json = JobQueue.Jobs.toJson(j)
  assertTrue(json.indexOf("\"id\":99") >= 0, "id present")
}

test "toJson includes kind" {
  val j = Job(
    id = 1,
    kind = "echo",
    payload = "{}",
    status = JobStatus.Pending,
    retryCount = 0,
    maxRetries = 3,
    workerId = "",
    error = "",
    createdAt = "2024-01-15T00:00:00Z"
  )
  val json = JobQueue.Jobs.toJson(j)
  assertTrue(json.indexOf("echo") >= 0, "kind present")
}

test "toJson encodes status as string label" {
  val j = Job(
    id = 1,
    kind = "noop",
    payload = "{}",
    status = JobStatus.Running,
    retryCount = 0,
    maxRetries = 3,
    workerId = "worker-1",
    error = "",
    createdAt = "2024-01-15T00:00:00Z"
  )
  val json = JobQueue.Jobs.toJson(j)
  assertTrue(json.indexOf("running") >= 0, "status label present")
}

test "toJson includes retry_count" {
  val j = Job(
    id = 1,
    kind = "noop",
    payload = "{}",
    status = JobStatus.Failed,
    retryCount = 2,
    maxRetries = 3,
    workerId = "",
    error = "timeout",
    createdAt = "2024-01-15T00:00:00Z"
  )
  val json = JobQueue.Jobs.toJson(j)
  assertTrue(json.indexOf("\"retry_count\":2") >= 0, "retry_count present")
}

test "toJson includes max_retries" {
  val j = Job(
    id = 1,
    kind = "noop",
    payload = "{}",
    status = JobStatus.Pending,
    retryCount = 0,
    maxRetries = 5,
    workerId = "",
    error = "",
    createdAt = "2024-01-15T00:00:00Z"
  )
  val json = JobQueue.Jobs.toJson(j)
  assertTrue(json.indexOf("\"max_retries\":5") >= 0, "max_retries present")
}

test "toJson includes worker_id" {
  val j = Job(
    id = 1,
    kind = "noop",
    payload = "{}",
    status = JobStatus.Running,
    retryCount = 0,
    maxRetries = 3,
    workerId = "worker-42",
    error = "",
    createdAt = "2024-01-15T00:00:00Z"
  )
  val json = JobQueue.Jobs.toJson(j)
  assertTrue(json.indexOf("worker-42") >= 0, "worker_id present")
}

test "toJson includes error field" {
  val j = Job(
    id = 1,
    kind = "noop",
    payload = "{}",
    status = JobStatus.Failed,
    retryCount = 3,
    maxRetries = 3,
    workerId = "",
    error = "connection refused",
    createdAt = "2024-01-15T00:00:00Z"
  )
  val json = JobQueue.Jobs.toJson(j)
  assertTrue(json.indexOf("connection refused") >= 0, "error message present")
}

test "toJson encodes completed status" {
  val j = Job(
    id = 1,
    kind = "noop",
    payload = "{}",
    status = JobStatus.Completed,
    retryCount = 0,
    maxRetries = 3,
    workerId = "worker-1",
    error = "",
    createdAt = "2024-01-15T00:00:00Z"
  )
  val json = JobQueue.Jobs.toJson(j)
  assertTrue(json.indexOf("completed") >= 0, "completed status present")
}

test "toJson encodes zero retry_count" {
  val j = Job(
    id = 1,
    kind = "noop",
    payload = "{}",
    status = JobStatus.Pending,
    retryCount = 0,
    maxRetries = 3,
    workerId = "",
    error = "",
    createdAt = "2024-01-15T00:00:00Z"
  )
  val json = JobQueue.Jobs.toJson(j)
  assertTrue(json.indexOf("\"retry_count\":0") >= 0, "zero retry_count present")
}
