// tests/jobs_tests.l — tests for the pure-Lyric surface of the Jobs package.
//
// Covers JobStatus, JobSpec, JobError, JobResult construction, and the
// InProcessJobScheduler with a synchronous in-process handler.
// NativeJobScheduler (Hangfire / Quartz) requires infrastructure and is
// not tested here.

@test_module
package Jobs.JobsTests

import Std.Core
import Std.Testing
import Jobs

// ─── JobStatus ───────────────────────────────────────────────────────────────

test "JobStatus.Pending: can be matched" {
  val s = JobStatus.Pending
  match s {
    case JobStatus.Pending -> ()
    case _                 -> assertTrue(false, "expected Pending")
  }
}

test "JobStatus.Running: can be matched" {
  val s = JobStatus.Running
  match s {
    case JobStatus.Running -> ()
    case _                 -> assertTrue(false, "expected Running")
  }
}

test "JobStatus.Succeeded: can be matched" {
  val s = JobStatus.Succeeded
  match s {
    case JobStatus.Succeeded -> ()
    case _                   -> assertTrue(false, "expected Succeeded")
  }
}

test "JobStatus.Failed: can be matched" {
  val s = JobStatus.Failed
  match s {
    case JobStatus.Failed -> ()
    case _                -> assertTrue(false, "expected Failed")
  }
}

test "JobStatus.Cancelled: can be matched" {
  val s = JobStatus.Cancelled
  match s {
    case JobStatus.Cancelled -> ()
    case _                   -> assertTrue(false, "expected Cancelled")
  }
}

// ─── JobSpec ─────────────────────────────────────────────────────────────────

test "JobSpec: fields are accessible" {
  val spec = JobSpec(
    id          = "job-1",
    name        = "send-email",
    payload     = "{\"to\":\"user@example.com\"}",
    maxAttempts = 3,
    timeoutMs   = 30000,
    scheduledAt = 0L)
  assertEqual(spec.id,      "job-1",      "id field")
  assertEqual(spec.name,    "send-email", "name field")
  assertEqualInt(spec.maxAttempts, 3,     "maxAttempts field")
  assertEqualInt(spec.timeoutMs,   30000, "timeoutMs field")
  assertTrue(spec.scheduledAt == 0L, "scheduledAt 0 means immediate")
}

test "JobSpec: scheduledAt non-zero is valid (deferred job)" {
  val spec = JobSpec(
    id          = "job-2",
    name        = "nightly-report",
    payload     = "",
    maxAttempts = 1,
    timeoutMs   = 60000,
    scheduledAt = 1735689600000L)
  assertTrue(spec.scheduledAt > 0L, "deferred job has non-zero scheduledAt")
}

// ─── JobError ─────────────────────────────────────────────────────────────────

test "JobError: fields are accessible" {
  val e = JobError(message = "SMTP timeout", code = "SMTP_TIMEOUT")
  assertEqual(e.message, "SMTP timeout", "message field")
  assertEqual(e.code,    "SMTP_TIMEOUT", "code field")
}

test "JobError: empty code is valid" {
  val e = JobError(message = "handler panicked", code = "")
  assertEqual(e.code, "", "empty code is valid")
}

// ─── JobResult ────────────────────────────────────────────────────────────────

test "JobResult: fields are accessible" {
  val r = JobResult(
    jobId      = "job-1",
    status     = JobStatus.Succeeded,
    output     = "sent",
    error      = "",
    startedAt  = 1000L,
    finishedAt = 1500L)
  assertEqual(r.jobId,  "job-1",  "jobId field")
  assertEqual(r.output, "sent",   "output field")
  assertEqual(r.error,  "",       "error field is empty on success")
  assertTrue(r.finishedAt > r.startedAt, "finishedAt is after startedAt")
  match r.status {
    case JobStatus.Succeeded -> ()
    case _                   -> assertTrue(false, "status must be Succeeded")
  }
}

test "JobResult: failed result carries error field" {
  val r = JobResult(
    jobId      = "job-2",
    status     = JobStatus.Failed,
    output     = "",
    error      = "connection refused",
    startedAt  = 2000L,
    finishedAt = 2100L)
  assertEqual(r.error, "connection refused", "error field on failure")
  match r.status {
    case JobStatus.Failed -> ()
    case _                -> assertTrue(false, "status must be Failed")
  }
}

// ─── inProcess / enqueue ─────────────────────────────────────────────────────

test "inProcess: creates scheduler with empty queue" {
  val scheduler = Jobs.inProcess()
  assertTrue(scheduler.queue.length == 0, "fresh scheduler has empty queue")
}

test "enqueue: adds a job to the in-process queue" {
  val scheduler = Jobs.inProcess()
  match Jobs.enqueue(scheduler, "my-job", "{}") {
    case Err(e) ->
      assertTrue(false, "enqueue must succeed: " + e)
    case Ok(jobId) -> {
      assertTrue(jobId.length > 0, "enqueue returns non-empty job ID")
      assertTrue(scheduler.queue.length == 1, "queue has one job after enqueue")
    }
  }
}

test "enqueue: successive enqueues each produce a unique job ID" {
  val scheduler = Jobs.inProcess()
  match Jobs.enqueue(scheduler, "job-a", "{}") {
    case Err(e)   -> assertTrue(false, "first enqueue failed: " + e)
    case Ok(id1) -> {
      match Jobs.enqueue(scheduler, "job-b", "{}") {
        case Err(e)   -> assertTrue(false, "second enqueue failed: " + e)
        case Ok(id2) -> {
          assertTrue(id1 != id2, "successive enqueues must produce distinct IDs")
          assertTrue(scheduler.queue.length == 2, "queue has two jobs")
        }
      }
    }
  }
}
