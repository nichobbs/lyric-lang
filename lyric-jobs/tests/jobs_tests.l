//! tests/jobs_tests.l — tests for the pure-Lyric surface of the Jobs package.
//!
//! Covers JobStatus, JobSpec, JobError, JobResult construction, and the
//! InProcessJobScheduler with a synchronous in-process handler.
//! NativeJobScheduler (Hangfire / Quartz) requires infrastructure and is
//! not tested here.
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
    case _ -> assertTrue(false, "expected Pending")
  }
}

test "JobStatus.Running: can be matched" {
  val s = JobStatus.Running
  match s {
    case JobStatus.Running -> ()
    case _ -> assertTrue(false, "expected Running")
  }
}

test "JobStatus.Succeeded: can be matched" {
  val s = JobStatus.Succeeded
  match s {
    case JobStatus.Succeeded -> ()
    case _ -> assertTrue(false, "expected Succeeded")
  }
}

test "JobStatus.Failed: can be matched" {
  val s = JobStatus.Failed
  match s {
    case JobStatus.Failed -> ()
    case _ -> assertTrue(false, "expected Failed")
  }
}

test "JobStatus.Cancelled: can be matched" {
  val s = JobStatus.Cancelled
  match s {
    case JobStatus.Cancelled -> ()
    case _ -> assertTrue(false, "expected Cancelled")
  }
}

// ─── JobSpec ─────────────────────────────────────────────────────────────────
test "JobSpec: fields are accessible" {
  val spec = JobSpec(
    id = "job-1",
    name = "send-email",
    payload = "{\"to\":\"user@example.com\"}",
    maxAttempts = 3,
    timeoutMs = 30000,
    scheduledAt = 0i64
  )
  assertEqual(spec.id, "job-1", "id field")
  assertEqual(spec.name, "send-email", "name field")
  assertEqualInt(spec.maxAttempts, 3, "maxAttempts field")
  assertEqualInt(spec.timeoutMs, 30000, "timeoutMs field")
  assertTrue(spec.scheduledAt == 0i64, "scheduledAt 0 means immediate")
}

test "JobSpec: scheduledAt non-zero is valid (deferred job)" {
  val spec = JobSpec(
    id = "job-2",
    name = "nightly-report",
    payload = "",
    maxAttempts = 1,
    timeoutMs = 60000,
    scheduledAt = 1735689600000i64
  )
  assertTrue(spec.scheduledAt > 0i64, "deferred job has non-zero scheduledAt")
}

// ─── JobError ─────────────────────────────────────────────────────────────────
test "JobError: fields are accessible" {
  val e = JobError(message = "SMTP timeout", code = "SMTP_TIMEOUT")
  assertEqual(e.message, "SMTP timeout", "message field")
  assertEqual(e.code, "SMTP_TIMEOUT", "code field")
}

test "JobError: empty code is valid" {
  val e = JobError(message = "handler panicked", code = "")
  assertEqual(e.code, "", "empty code is valid")
}

// ─── JobResult ────────────────────────────────────────────────────────────────
test "JobResult: fields are accessible" {
  val r = JobResult(
    jobId = "job-1",
    status = JobStatus.Succeeded,
    output = "sent",
    error = "",
    startedAt = 1000i64,
    finishedAt = 1500i64
  )
  assertEqual(r.jobId, "job-1", "jobId field")
  assertEqual(r.output, "sent", "output field")
  assertEqual(r.error, "", "error field is empty on success")
  assertTrue(r.finishedAt > r.startedAt, "finishedAt is after startedAt")
  match r.status {
    case JobStatus.Succeeded -> ()
    case _ -> assertTrue(false, "status must be Succeeded")
  }
}

test "JobResult: failed result carries error field" {
  val r = JobResult(
    jobId = "job-2",
    status = JobStatus.Failed,
    output = "",
    error = "connection refused",
    startedAt = 2000i64,
    finishedAt = 2100i64
  )
  assertEqual(r.error, "connection refused", "error field on failure")
  match r.status {
    case JobStatus.Failed -> ()
    case _ -> assertTrue(false, "status must be Failed")
  }
}

// ─── inProcess / enqueue ─────────────────────────────────────────────────────
test "inProcess: creates scheduler with empty queue" {
  val scheduler = Jobs.inProcess()
  assertTrue(scheduler.queue.length == 0, "fresh scheduler has empty queue")
}

test "enqueue: adds a job to the in-process queue" {
  val scheduler = Jobs.inProcess()
  match scheduler.enqueue("my-job", "{}", 3, 30000) {
    case Err(e) -> assertTrue(false, "enqueue must succeed: " + e)
    case Ok(jobId) -> {
      assertTrue(jobId.length > 0, "enqueue returns non-empty job ID")
      assertTrue(scheduler.queue.length == 1, "queue has one job after enqueue")
    }
  }
}

test "enqueue: successive enqueues each produce a unique job ID" {
  val scheduler = Jobs.inProcess()
  match scheduler.enqueue("job-a", "{}", 3, 30000) {
    case Err(e) -> assertTrue(false, "first enqueue failed: " + e)
    case Ok(id1) -> {
      match scheduler.enqueue("job-b", "{}", 3, 30000) {
        case Err(e) -> assertTrue(false, "second enqueue failed: " + e)
        case Ok(id2) -> {
          assertTrue(id1 != id2, "successive enqueues must produce distinct IDs")
          assertTrue(scheduler.queue.length == 2, "queue has two jobs")
        }
      }
    }
  }
}

// ─── enqueue / enqueueWith convenience wrappers ───────────────────────────────
test "enqueue wrapper: uses default limits and queues the job (#3174)" {
  val scheduler = Jobs.inProcess()
  match Jobs.enqueue(scheduler, "wrapped-job", "{}") {
    case Err(e) -> assertTrue(false, "enqueue wrapper must succeed: " + e)
    case Ok(jobId) -> {
      assertTrue(jobId.length > 0, "enqueue wrapper returns non-empty job ID")
      assertTrue(scheduler.queue.length == 1, "queue has one job after enqueue wrapper")
    }
  }
}

test "enqueueWith wrapper: honours explicit maxAttempts/timeoutMs (#3174, #3515)" {
  val scheduler = Jobs.inProcess()
  match Jobs.enqueueWith(scheduler, "tuned-job", "{}", 5, 60000) {
    case Err(e) -> assertTrue(false, "enqueueWith wrapper must succeed: " + e)
    case Ok(jobId) -> {
      assertTrue(jobId.length > 0, "enqueueWith wrapper returns non-empty job ID")
      assertTrue(scheduler.queue.length == 1, "queue has one job after enqueueWith wrapper")
      // Assert the explicit retry/timeout actually reached the stored JobSpec,
      // not just that the job was queued (#3515).
      val spec = scheduler.queue[0]
      assertEqual(spec.name, "tuned-job", "stored spec name")
      assertEqualInt(spec.maxAttempts, 5, "stored spec maxAttempts honours the explicit argument")
      assertEqualInt(spec.timeoutMs, 60000, "stored spec timeoutMs honours the explicit argument")
    }
  }
}
